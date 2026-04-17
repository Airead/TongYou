import AppKit
import Metal
import QuartzCore
import TYTerminal

/// NSView subclass hosting a CAMetalLayer for GPU rendering.
/// Bridged into SwiftUI via TerminalPaneContainerView (NSViewRepresentable).
final class MetalView: NSView {

    private var metalLayer: CAMetalLayer!
    private var device: MTLDevice!
    private(set) var renderer: MetalRenderer?
    var currentResourceMetrics: ResourceMetrics {
        renderer?.currentResourceMetrics ?? ResourceMetrics()
    }
    private var fontSystem: FontSystem?
    private var terminalController: (any TerminalControlling)?
    // nonisolated(unsafe) because deinit must invalidate without actor hop
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var cursorBlinkTimer: Timer?

    /// Working directory for the shell spawned in this tab.
    var initialWorkingDirectory: String?

    /// External controller injected for remote sessions.
    /// When set, MetalView skips creating a local TerminalController.
    var externalController: (any TerminalControlling)?

    /// Configuration loader with hot reload support.
    private let configLoader = ConfigLoader()

    /// Accumulated sub-cell scroll delta for precise (trackpad) scrolling.
    private var pendingScrollY: Double = 0
    /// Lines per discrete mouse-wheel tick.
    private static let discreteScrollMultiplier = 3

    // nonisolated(unsafe) because deinit must invalidate without actor hop
    nonisolated(unsafe) private var dragAutoScrollTimer: Timer?
    /// Last known drag column (for auto-scroll timer updates).
    private var dragLastCol: Int = 0
    /// Last known unclamped drag row (for auto-scroll timer updates).
    private var dragLastUnclampedRow: Int = 0
    /// Last consumed content generation for display-link deduplication.
    private var lastRenderedContentGeneration: UInt64 = .max

    /// The pane ID this MetalView belongs to (set by TerminalPaneContainerView).
    var paneID: UUID?

    /// Blue notification ring overlay (sublayer of the CAMetalLayer).
    private let notificationRingLayer = CAShapeLayer()
    /// Guards against overlapping flash animations from rapid notifications.
    private var isFlashing = false

    /// Callback for keybinding actions (forwarded to SessionManager via TerminalWindowView).
    var onTabAction: ((TabAction) -> Void)?

    /// Returns true if this pane's process has exited (for ESC-to-close floating panes).
    var isProcessExited: (() -> Bool)?

    /// Called on any keyboard or mouse interaction to indicate the pane is active.
    var onUserInteraction: (() -> Void)?

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

    // MARK: - Search State

    /// The search bar overlay (nil when search is inactive).
    private var searchBar: SearchBarView?
    /// Current search result with matches and focused index.
    private var searchResult: SearchResult = .empty

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

        MetalViewRegistry.shared.register(self)

        notificationRingLayer.fillColor = nil
        notificationRingLayer.strokeColor = NSColor.systemBlue.cgColor
        notificationRingLayer.lineWidth = 2
        notificationRingLayer.opacity = 0
        layer?.addSublayer(notificationRingLayer)
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
        onUserInteraction?()

        // ESC closes an exited floating pane.
        if event.keyCode == 53,  // ESC key
           isProcessExited?() == true,
           let paneID {
            onTabAction?(.closeFloatingPane(paneID))
            return
        }

        // Enter re-runs the command in an exited floating pane.
        if event.keyCode == 36,  // Enter key
           isProcessExited?() == true,
           let paneID {
            onTabAction?(.rerunFloatingPaneCommand(paneID))
            return
        }

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
        // Only handle key equivalents when this view is the first responder.
        // performKeyEquivalent traverses the entire view hierarchy, not just
        // the first responder. Without this guard the first MetalView in the
        // tree would swallow shortcuts (e.g. Cmd+V paste) meant for another pane.
        guard window?.firstResponder === self else { return false }

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
            toggleSearchBar()
            return true
        case .searchNext:
            navigateSearch(forward: true)
            return true
        case .searchPrevious:
            navigateSearch(forward: false)
            return true
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

    // MARK: - Search

    private func toggleSearchBar() {
        if searchBar != nil {
            closeSearchBar()
        } else {
            openSearchBar()
        }
    }

    private func openSearchBar() {
        guard searchBar == nil else {
            searchBar?.activate()
            return
        }
        let bar = SearchBarView(
            frame: .zero,
            themeBackground: configLoader.config.background.nsColor,
            themeForeground: configLoader.config.foreground.nsColor
        )
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: SearchBarView.barHeight + 8),
        ])

        bar.onQueryChanged = { [weak self] query in
            self?.performSearch(query: query)
        }
        bar.onNext = { [weak self] in
            self?.navigateSearch(forward: true)
        }
        bar.onPrevious = { [weak self] in
            self?.navigateSearch(forward: false)
        }
        bar.onClose = { [weak self] in
            self?.closeSearchBar()
        }

        searchBar = bar
        bar.activate()
    }

    private func closeSearchBar() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        searchResult = .empty
        renderer?.searchResult = nil  // didSet triggers markDirty
        wakeDisplayLink()
        window?.makeFirstResponder(self)
    }

    private func performSearch(query: String) {
        guard let tc = terminalController, !query.isEmpty else {
            searchResult = .empty
            renderer?.searchResult = nil  // didSet triggers markDirty
            wakeDisplayLink()
            searchBar?.updateMatchCount(current: nil, total: 0)
            return
        }

        searchResult = tc.search(query: query)
        renderer?.searchResult = searchResult
        searchBar?.updateMatchCount(current: searchResult.focusedIndex, total: searchResult.count)

        // Scroll to the focused match if it exists.
        if let match = searchResult.focusedMatch {
            tc.scrollToLine(match.line)
        }

        wakeDisplayLink()
    }

    private func navigateSearch(forward: Bool) {
        guard !searchResult.isEmpty else { return }
        if forward { searchResult.focusNext() } else { searchResult.focusPrevious() }
        renderer?.searchResult = searchResult
        searchBar?.updateMatchCount(current: searchResult.focusedIndex, total: searchResult.count)

        if let match = searchResult.focusedMatch {
            terminalController?.scrollToLine(match.line)
        }
        wakeDisplayLink()
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

    /// Returns true when the Option (Alt) key is held, forcing local text
    /// selection even if the terminal program has enabled mouse tracking.
    private func isAltForcingSelection(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.option)
    }

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
        onUserInteraction?()
        onFocused?()
        let inMouseMode = isMouseTrackingActive
        let forceSelection = isAltForcingSelection(event)

        // Cmd+Click: open URL
        if event.modifierFlags.contains(.command) {
            terminalController?.setCommandKeyHeld(true)
            let (col, row) = gridPosition(for: event)
            if terminalController?.openURL(at: row, col: col) == true {
                return
            }
        }

        if inMouseMode && !forceSelection {
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
        stopDragAutoScrollTimer()
        if isMouseTrackingActive && !isAltForcingSelection(event) {
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
        if isMouseTrackingActive && !isAltForcingSelection(event) {
            sendMouseEvent(event, action: .motion, button: .left)
        } else {
            let (col, unclampedRow) = gridPosition(for: event, clampRow: false)
            let visibleRows = Int(renderer?.gridSize.rows ?? 1)

            dragLastCol = col
            dragLastUnclampedRow = unclampedRow

            if unclampedRow < 0 || unclampedRow >= visibleRows {
                terminalController?.updateSelectionWithAutoScroll(
                    col: col, viewportRow: unclampedRow)
                startDragAutoScrollTimer()
            } else {
                stopDragAutoScrollTimer()
                terminalController?.updateSelection(col: col, row: unclampedRow)
            }
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
    /// When `clampRow` is false, row may be negative (above) or >= rows (below).
    private func gridPosition(for event: NSEvent, clampRow: Bool = true) -> (col: Int, row: Int) {
        guard let fontSystem, let renderer else { return (0, 0) }
        let viewPos = convert(event.locationInWindow, from: nil)
        let scale = displayScale
        let pixelX = viewPos.x * scale
        let pixelY = (bounds.height - viewPos.y) * scale
        let col = max(0, min(Int(pixelX / CGFloat(fontSystem.cellSize.width)),
                             Int(renderer.gridSize.columns) - 1))
        let rawRow = Int(floor(pixelY / CGFloat(fontSystem.cellSize.height)))
        let row = clampRow ? max(0, min(rawRow, Int(renderer.gridSize.rows) - 1)) : rawRow
        return (col, row)
    }

    // MARK: - Drag Auto-Scroll

    private func startDragAutoScrollTimer() {
        guard dragAutoScrollTimer == nil else { return }
        dragAutoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.terminalController?.updateSelectionWithAutoScroll(
                col: self.dragLastCol,
                viewportRow: self.dragLastUnclampedRow)
        }
    }

    private func stopDragAutoScrollTimer() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
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
                if self.searchBar == nil {
                    self.window?.makeFirstResponder(self)
                }
                if wasAlreadySetUp {
                    // Re-inserted after tab switch — force full redraw.
                    // setupIfNeeded already called updateDrawableSize above.
                    self.renderer?.markDirty()
                }
                // Always wake the display link — for newly created views,
                // a screenFull snapshot may already be waiting in the replica.
                self.wakeDisplayLink()
            } else {
                self.stopDragAutoScrollTimer()
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
            let shared = SharedAtlasProvider.shared
            renderer = MetalRenderer(device: device, fontSystem: fs, config: config,
                                     glyphAtlas: shared.glyphAtlas, emojiAtlas: shared.emojiAtlas)

            configLoader.onConfigChanged = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
        }

        setupTerminalControllerIfNeeded()
    }

    private func configureController(_ controller: any TerminalControlling) {
        if let grid = renderer?.gridSize, grid.columns > 0, grid.rows > 0 {
            controller.resize(
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                cellWidth: 0, cellHeight: 0
            )
        }
        controller.applyConfig(configLoader.config)
    }

    private func wireDisplayCallbacks(_ controller: any TerminalControlling) {
        controller.onNeedsDisplay = { [weak self] in
            if Thread.isMainThread {
                self?.wakeDisplayLink()
            } else {
                DispatchQueue.main.async { self?.wakeDisplayLink() }
            }
        }
        controller.onTitleChanged = { [weak self] title in
            self?.onTitleChanged?(title)
        }
    }

    private func wireControllerCallbacks(_ controller: any TerminalControlling) {
        wireDisplayCallbacks(controller)
        controller.onProcessExited = { [weak self] in
            guard let self, let paneID = self.paneID else { return }
            self.onTabAction?(.paneExited(paneID))
        }
        controller.onPaneNotification = { [weak self] title, body in
            guard let self, let paneID = self.paneID else { return }
            self.onTabAction?(.paneNotification(paneID, title, body))
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
        // Do NOT stop the terminalController here — its lifecycle is managed
        // by SessionManager (local) or the remote client (remote).
        terminalController = nil
        renderer = nil
        MetalViewRegistry.shared.unregister(self)
    }

    @objc nonisolated private func displayLinkFired(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            if let snapshot = self.terminalController?.consumeSnapshot() {
                let gen = self.terminalController?.contentGeneration ?? 0
                if gen != self.lastRenderedContentGeneration {
                    self.lastRenderedContentGeneration = gen
                    self.renderer?.setContent(snapshot)
                } else {
                    self.renderer?.recordDedupedFrame()
                }
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
            self.updateNotificationRingPath()
        }
    }

    func setNotificationRing(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    private func updateNotificationRingPath() {
        let inset: CGFloat = 2
        let radius: CGFloat = 6
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        notificationRingLayer.path = path
    }

    func flashNotificationRing() {
        guard !isFlashing else { return }
        isFlashing = true

        let flashLayer = CALayer()
        flashLayer.frame = bounds
        flashLayer.backgroundColor = NSColor.systemBlue.cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.6, 0, 0.6, 0]
        animation.duration = 0.9
        animation.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak flashLayer] in
            flashLayer?.removeFromSuperlayer()
            self?.isFlashing = false
        }
        flashLayer.add(animation, forKey: "flash")
        CATransaction.commit()
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

        setupTerminalControllerIfNeeded()

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

    private func setupTerminalControllerIfNeeded() {
        guard terminalController == nil,
              let grid = renderer?.gridSize,
              grid.columns > 0, grid.rows > 0 else { return }

        let controller: any TerminalControlling
        if let external = externalController {
            configureController(external)
            controller = external
        } else {
            let config = configLoader.config
            let tc = TerminalController(
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                config: config
            )
            tc.start(workingDirectory: initialWorkingDirectory)
            controller = tc
        }
        wireControllerCallbacks(controller)
        terminalController = controller
    }

    func bindController(_ controller: any TerminalControlling) {
        terminalController?.onProcessExited = nil
        terminalController?.onNeedsDisplay = nil
        terminalController?.onTitleChanged = nil

        configureController(controller)
        wireDisplayCallbacks(controller)
        if controller.onProcessExited == nil {
            controller.onProcessExited = { [weak self] in
                guard let self, let paneID = self.paneID else { return }
                self.onTabAction?(.paneExited(paneID))
            }
        }
        terminalController = controller
        renderer?.markDirty()
        lastRenderedContentGeneration = .max
        wakeDisplayLink()
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        dragAutoScrollTimer?.invalidate()
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
