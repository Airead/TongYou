import AppKit
import Metal
import QuartzCore

/// NSView subclass hosting a CAMetalLayer for GPU rendering.
/// Bridged into SwiftUI via TerminalPaneContainerView (NSViewRepresentable).
final class MetalView: NSView {

    private var metalLayer: CAMetalLayer!
    private var device: MTLDevice!
    private var renderer: MetalRenderer?
    private var fontSystem: FontSystem?
    private var terminalController: TerminalController?
    // nonisolated(unsafe) because deinit must invalidate without actor hop
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var cursorBlinkTimer: Timer?

    /// Working directory for the shell spawned in this tab.
    var initialWorkingDirectory: String?

    /// Configuration loader with hot reload support.
    private let configLoader = ConfigLoader()

    /// Accumulated sub-cell scroll delta for precise (trackpad) scrolling.
    private var pendingScrollY: Double = 0
    /// Lines per discrete mouse-wheel tick.
    private static let discreteScrollMultiplier = 3

    /// The pane ID this MetalView belongs to (set by TerminalPaneContainerView).
    var paneID: UUID?

    /// Callback for tab-related keybinding actions (forwarded to TabManager).
    var onTabAction: ((TabAction) -> Void)?

    /// Callback when the window title changes (from OSC 0/2).
    var onTitleChanged: ((String) -> Void)?

    /// Callback when this pane receives focus (mouse click).
    var onFocused: (() -> Void)?

    // MARK: - IME State

    /// Stores the in-progress composition text from the input method.
    private var markedText = NSMutableAttributedString()
    /// Accumulates committed text during a single keyDown event cycle.
    /// Non-nil means we are inside a keyDown → interpretKeyEvents flow.
    private var keyTextAccumulator: [String]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        device = mtlDevice

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Set default background so the layer isn't transparent before the first Metal frame.
        // Use theme-resolved config so the color matches the actual theme.
        let bg = Config.from(entries: []).background
        layer.backgroundColor = CGColor(
            srgbRed: CGFloat(bg.r) / 255.0,
            green: CGFloat(bg.g) / 255.0,
            blue: CGFloat(bg.b) / 255.0,
            alpha: 1.0
        )
        metalLayer = layer
        return layer
    }

    // MARK: - Helpers

    private var displayScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            startCursorBlinkTimer()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            hideCursor()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        // Check keybindings first for Option+key combinations that
        // performKeyEquivalent may not intercept (macOS routes these
        // through keyDown rather than performKeyEquivalent).
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.option) && !mods.contains(.command)
            && !shouldPassthrough(modifiers: mods) {
            let bindings = configLoader.config.keybindings
            if let action = Keybinding.match(event: event, in: bindings),
               performAction(action) {
                return
            }
        }

        // Bypass interpretKeyEvents for Option+key when optionAsAlt is on,
        // otherwise macOS turns e.g. Option+F into "ƒ" instead of ESC f.
        // Still route through interpretKeyEvents when IME has marked text.
        let optionAsAlt = configLoader.config.optionAsAlt
        if optionAsAlt
            && mods.contains(.option)
            && !mods.contains(.command)
            && markedText.length == 0
        {
            terminalController?.handleKeyDown(event)
            return
        }

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0

        // Route through the macOS text input system. This triggers
        // NSTextInputClient callbacks: setMarkedText / insertText / doCommand.
        interpretKeyEvents([event])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            // IME committed text — send as a single write to the PTY.
            terminalController?.sendText(texts.joined())
        } else if markedText.length == 0 && !hadMarkedText {
            // No IME activity — fall back to the key encoder path.
            terminalController?.handleKeyDown(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only intercept modifier key combinations we handle.
        let deviceMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !deviceMods.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        if shouldPassthrough(modifiers: deviceMods) {
            return false
        }

        let bindings = configLoader.config.keybindings
        if let action = Keybinding.match(event: event, in: bindings) {
            return performAction(action)
        }

        return false
    }

    private func performAction(_ action: Keybinding.Action) -> Bool {
        if action == .unbind { return false }
        // Actions that map directly to TabAction.
        if let tabAction = action.tabAction {
            onTabAction?(tabAction)
            return true
        }
        // Actions handled locally by the MetalView.
        switch action {
        case .paste:
            handlePaste()
            return true
        case .copy:
            return terminalController?.copySelection() == true
        case .search:
            return false
        case .resetFontSize, .increaseFontSize, .decreaseFontSize:
            return false
        default:
            return false
        }
    }

    /// Whether the foreground process is in the auto-passthrough list.
    /// Checks both the shell-integration running command (works over SSH)
    /// and the local foreground process name (fallback).
    private func shouldPassthrough(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !modifiers.contains(.command) else { return false }
        let programs = configLoader.config.autoPassthroughPrograms
        guard !programs.isEmpty else { return false }

        // Shell integration: running command reported via OSC 7727.
        if let cmd = terminalController?.runningCommand?.lowercased(),
           programs.contains(cmd) {
            return true
        }

        // Fallback: local foreground process detection via tcgetpgrp.
        if let name = terminalController?.foregroundProcessName?.lowercased(),
           programs.contains(name) {
            return true
        }

        return false
    }

    private func handlePaste() {
        guard let string = NSPasteboard.general.string(forType: .string),
              !string.isEmpty else { return }
        terminalController?.handlePaste(string)
    }

    // MARK: - Mouse Events

    /// Whether the terminal program has enabled mouse tracking (e.g. vim, zellij).
    private var isMouseTrackingActive: Bool {
        // Unwrap explicitly: `optional != .none` resolves .none as Optional.none,
        // not MouseTrackingMode.none, so .some(.none) would incorrectly pass.
        guard let mode = terminalController?.mouseTrackingMode else { return false }
        return mode != .none
    }

    /// Click count tracking for double/triple click.
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int = 0
    private static let multiClickInterval: TimeInterval = 0.3

    /// Currently hovered URL (Cmd held + mouse over URL).
    private var hoveredURL: DetectedURL?

    override func flagsChanged(with event: NSEvent) {
        let cmdHeld = event.modifierFlags.contains(.command)
        terminalController?.setCommandKeyHeld(cmdHeld)
        if cmdHeld {
            let (col, row) = gridPosition(for: event)
            updateHoveredURL(at: row, col: col)
        } else {
            clearHoveredURL()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        let inMouseMode = isMouseTrackingActive

        // Cmd+Click: open URL
        if event.modifierFlags.contains(.command) {
            terminalController?.setCommandKeyHeld(true)
            let (col, row) = gridPosition(for: event)
            if terminalController?.openURL(at: row, col: col) == true {
                return
            }
        }

        if inMouseMode {
            sendMouseEvent(event, action: .press, button: .left)
            return
        }

        // Terminal-side selection
        let (col, row) = gridPosition(for: event)
        let now = event.timestamp
        if now - lastClickTime < Self.multiClickInterval {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now

        switch clickCount {
        case 2:
            terminalController?.startSelection(col: col, row: row, mode: .word)
        case 3:
            terminalController?.startSelection(col: col, row: row, mode: .line)
            clickCount = 0
        default:
            terminalController?.startSelection(col: col, row: row, mode: .character)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isMouseTrackingActive {
            sendMouseEvent(event, action: .release, button: .left)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isMouseTrackingActive {
            sendMouseEvent(event, action: .press, button: .right)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if isMouseTrackingActive {
            sendMouseEvent(event, action: .release, button: .right)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseEvent(event, action: .press, button: .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseEvent(event, action: .release, button: .middle)
    }

    override func mouseMoved(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            terminalController?.setCommandKeyHeld(true)
            let (col, row) = gridPosition(for: event)
            updateHoveredURL(at: row, col: col)
        } else {
            if hoveredURL != nil { clearHoveredURL() }
        }
        sendMouseEvent(event, action: .motion, button: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        if isMouseTrackingActive {
            sendMouseEvent(event, action: .motion, button: .left)
        } else {
            // Update selection during drag
            let (col, row) = gridPosition(for: event)
            terminalController?.updateSelection(col: col, row: row)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouseEvent(event, action: .motion, button: .right)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouseEvent(event, action: .motion, button: .middle)
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0, let fontSystem else { return }

        let cellHeight = Double(fontSystem.cellSize.height)

        if event.phase == .began {
            pendingScrollY = 0
        }

        // Positive delta = scroll toward older content.
        let delta: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate pixel deltas, scroll only when a full
            // cell height is reached, and carry the remainder forward.
            pendingScrollY += deltaY
            if abs(pendingScrollY) < cellHeight {
                return
            }
            let amount = pendingScrollY / cellHeight
            let truncated = amount.rounded(.towardZero)
            delta = Int(truncated)
            pendingScrollY -= truncated * cellHeight
        } else {
            let ticks = max(1, Int(abs(deltaY)))
            delta = deltaY > 0
                ? ticks * Self.discreteScrollMultiplier
                : -ticks * Self.discreteScrollMultiplier
        }

        let lines = abs(delta)

        if isMouseTrackingActive {
            let button: MouseEncoder.Button = delta > 0 ? .scrollUp : .scrollDown
            for _ in 0..<lines {
                sendMouseEvent(event, action: .press, button: button)
            }
        } else {
            if delta > 0 {
                terminalController?.scrollUp(lines: lines)
            } else {
                terminalController?.scrollDown(lines: lines)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredURL != nil { clearHoveredURL() }
    }

    // MARK: - URL Hover Helpers

    private func updateHoveredURL(at row: Int, col: Int) {
        if let url = terminalController?.urlAt(row: row, col: col) {
            if hoveredURL != url {
                hoveredURL = url
                renderer?.highlightedURL = url
                NSCursor.pointingHand.set()
            }
        } else {
            if hoveredURL != nil { clearHoveredURL() }
        }
    }

    private func clearHoveredURL() {
        hoveredURL = nil
        renderer?.highlightedURL = nil
        NSCursor.iBeam.set()
    }

    // MARK: - Mouse Helpers

    /// Convert an NSEvent's window location to grid (col, row).
    private func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        guard let fontSystem, let renderer else { return (0, 0) }
        let viewPos = convert(event.locationInWindow, from: nil)
        let scale = displayScale
        let pixelX = viewPos.x * scale
        let pixelY = (bounds.height - viewPos.y) * scale
        let col = max(0, min(Int(pixelX / CGFloat(fontSystem.cellSize.width)),
                             Int(renderer.gridSize.columns) - 1))
        let row = max(0, min(Int(pixelY / CGFloat(fontSystem.cellSize.height)),
                             Int(renderer.gridSize.rows) - 1))
        return (col, row)
    }

    private func sendMouseEvent(
        _ nsEvent: NSEvent,
        action: MouseEncoder.Action,
        button: MouseEncoder.Button?
    ) {
        let (col, row) = gridPosition(for: nsEvent)
        let mods = MouseEncoder.Modifiers(
            shift: nsEvent.modifierFlags.contains(.shift),
            option: nsEvent.modifierFlags.contains(.option),
            control: nsEvent.modifierFlags.contains(.control)
        )
        let mouseEvent = MouseEncoder.Event(
            action: action, button: button,
            col: col, row: row, modifiers: mods
        )
        terminalController?.handleMouseEvent(mouseEvent)
    }

    // MARK: - View Lifecycle

    nonisolated override func viewDidMoveToWindow() {
        MainActor.assumeIsolated {
            if self.window != nil {
                let wasAlreadySetUp = self.renderer != nil
                self.setupIfNeeded()
                self.startDisplayLink()
                self.observeWindowActivation()
                self.window?.makeFirstResponder(self)
                if wasAlreadySetUp {
                    // Re-inserted after tab switch — force full redraw.
                    // setupIfNeeded already called updateDrawableSize above.
                    self.renderer?.markDirty()
                    self.wakeDisplayLink()
                }
            } else {
                self.stopDisplayLink()
                self.removeWindowActivationObservers()
            }
        }
    }

    private func observeWindowActivation() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidBecomeKey),
                       name: NSWindow.didBecomeKeyNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidResignKey),
                       name: NSWindow.didResignKeyNotification, object: window)
    }

    private func removeWindowActivationObservers() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard window?.firstResponder === self else { return }
        startCursorBlinkTimer()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        hideCursor()
    }

    private func setupIfNeeded() {
        guard let window = self.window else { return }
        let scale = window.backingScaleFactor

        metalLayer.contentsScale = scale
        updateDrawableSize()

        if renderer == nil {
            configLoader.load()
            let config = configLoader.config

            updateLayerBackground(config.background)

            let fs = FontSystem(
                fontName: config.fontFamily,
                pointSize: CGFloat(config.fontSize),
                scaleFactor: scale
            )
            fontSystem = fs
            renderer = MetalRenderer(device: device, fontSystem: fs, config: config)

            configLoader.onConfigChanged = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
        }

        if terminalController == nil, let grid = renderer?.gridSize {
            let config = configLoader.config
            let tc = TerminalController(
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                config: config
            )
            tc.onNeedsDisplay = { [weak self] in
                DispatchQueue.main.async {
                    self?.wakeDisplayLink()
                }
            }
            tc.onProcessExited = { [weak self] in
                guard let self, let paneID = self.paneID else { return }
                self.onTabAction?(.paneExited(paneID))
            }
            tc.onTitleChanged = { [weak self] title in
                self?.onTitleChanged?(title)
            }
            tc.start(workingDirectory: initialWorkingDirectory)
            terminalController = tc
        }
    }

    private func applyConfigChange(_ config: Config) {
        guard let renderer = renderer else { return }
        updateLayerBackground(config.background)
        let scale = displayScale

        // Check if font changed
        let oldFS = fontSystem
        let fontChanged = oldFS.map { fs in
            fs.pointSize != CGFloat(config.fontSize) ||
            CTFontCopyFamilyName(fs.ctFont) as String != config.fontFamily
        } ?? true

        var newFontSystem: FontSystem?
        if fontChanged {
            let fs = FontSystem(
                fontName: config.fontFamily,
                pointSize: CGFloat(config.fontSize),
                scaleFactor: scale
            )
            fontSystem = fs
            newFontSystem = fs
            pendingScrollY = 0
        }

        let didChangeFonts = renderer.applyConfig(config, fontSystem: newFontSystem)

        if didChangeFonts {
            // Font change means cell size changed — need to resize
            updateDrawableSize()
            let grid = renderer.gridSize
            terminalController?.resize(
                columns: Int(grid.columns),
                rows: Int(grid.rows)
            )
        }

        // Apply cursor blink setting (startCursorBlinkTimer handles both enabled/disabled)
        startCursorBlinkTimer()
        renderer.markCursorDirty()

        // Apply non-rendering config to terminal controller
        terminalController?.applyConfig(config)

        wakeDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        let link = self.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        startCursorBlinkTimer()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        stopCursorBlinkTimer()
    }

    private func startCursorBlinkTimer() {
        stopCursorBlinkTimer()
        guard configLoader.config.cursorBlink else {
            renderer?.cursorBlinkOn = true
            renderer?.markCursorDirty()
            wakeDisplayLink()
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let renderer = self.renderer else { return }
                renderer.cursorBlinkOn.toggle()
                renderer.markCursorDirty()
                self.wakeDisplayLink()
            }
        }
        timer.tolerance = 0.05
        cursorBlinkTimer = timer
    }

    private func stopCursorBlinkTimer() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
    }

    private func hideCursor() {
        stopCursorBlinkTimer()
        renderer?.cursorBlinkOn = false
        renderer?.markCursorDirty()
        wakeDisplayLink()
    }

    private func wakeDisplayLink() {
        displayLink?.isPaused = false
    }

    /// Query the current working directory of the shell in this tab.
    var currentWorkingDirectory: String? {
        terminalController?.currentWorkingDirectory
    }

    func tearDown() {
        stopDisplayLink()
        terminalController?.stop()
        terminalController = nil
        renderer = nil
    }

    @objc nonisolated private func displayLinkFired(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            if let snapshot = self.terminalController?.consumeSnapshot() {
                self.renderer?.setContent(snapshot)
            }
            guard let renderer = self.renderer, renderer.needsRender else {
                link.isPaused = true
                return
            }
            renderer.render(in: self.metalLayer)
            // Pause after the last pending frame so the CPU can idle.
            if !renderer.needsRender {
                link.isPaused = true
            }
        }
    }

    nonisolated override func viewDidChangeBackingProperties() {
        MainActor.assumeIsolated {
            guard let window = self.window else { return }
            self.metalLayer.contentsScale = window.backingScaleFactor
            self.updateDrawableSize()
        }
    }

    nonisolated override func setFrameSize(_ newSize: NSSize) {
        MainActor.assumeIsolated {
            super.setFrameSize(newSize)
            self.updateDrawableSize()
        }
    }

    private func updateLayerBackground(_ bg: RGBColor) {
        metalLayer.backgroundColor = CGColor(
            srgbRed: CGFloat(bg.r) / 255.0,
            green: CGFloat(bg.g) / 255.0,
            blue: CGFloat(bg.b) / 255.0,
            alpha: 1.0
        )
    }

    private func updateDrawableSize() {
        let scale = displayScale
        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)
        // Skip when bounds is zero (e.g. view just inserted, no frame yet).
        // setFrameSize will call us again once layout provides a real size.
        guard width > 0, height > 0 else { return }
        metalLayer.drawableSize = CGSize(width: Int(width), height: Int(height))
        renderer?.resize(screen: ScreenSize(width: width, height: height))

        if let grid = renderer?.gridSize, let fs = fontSystem {
            terminalController?.resize(
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                cellWidth: fs.cellSize.width,
                cellHeight: fs.cellSize.height
            )
        }
        wakeDisplayLink()
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - NSTextInputClient

extension MetalView: NSTextInputClient {

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let fontSystem, let renderer else {
            return window?.convertToScreen(frame) ?? frame
        }
        let scale = displayScale
        let snapshot = renderer.currentSnapshot

        // Cursor grid position (0-based)
        let cursorCol = snapshot?.cursorCol ?? 0
        let cursorRow = snapshot?.cursorRow ?? 0

        // Convert pixel coordinates to view (point) coordinates.
        // Renderer padding and cell size are in physical pixels.
        let padding = renderer.padding
        let cellW = CGFloat(fontSystem.cellSize.width)
        let cellH = CGFloat(fontSystem.cellSize.height)

        let pixelX = CGFloat(padding.left) + CGFloat(cursorCol) * cellW
        let pixelY = CGFloat(padding.top) + CGFloat(cursorRow) * cellH

        // Convert from physical pixels → view points
        let viewX = pixelX / scale
        let viewY = pixelY / scale
        let viewW = cellW / scale
        let viewH = cellH / scale

        // NSView coordinates are bottom-left origin
        let viewRect = NSRect(
            x: viewX,
            y: bounds.height - viewY - viewH,
            width: viewW,
            height: viewH
        )

        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
        } else {
            terminalController?.sendText(chars)
        }
    }

    override func doCommand(by selector: Selector) {
        // Suppress NSBeep for unhandled selectors during IME.
        // The key event will be handled by the fallback path in keyDown.
    }
}
