import Foundation
import TYTerminal
import TYPTY

/// Platform-independent terminal session core.
///
/// Manages PTY + VTParser + StreamHandler + Screen lifecycle.
/// No AppKit, no UI — pure backend logic suitable for both
/// the server daemon and headless testing.
///
/// ## Thread safety
///
/// `TerminalCore` is `@unchecked Sendable` because its mutable state is
/// serialized by `ptyQueue`, a custom serial `DispatchQueue` that the Swift
/// type system cannot see. `ptyQueue` plays the role an `actor` would; it
/// is kept as a queue (instead of converting this type to `actor`) because
/// PTY byte reads must preserve strict FIFO order, which actor re-entrancy
/// does not guarantee.
///
/// Invariants:
/// - `screen`, `vtParser`, `streamHandler`, `screenDirty`,
///   `focusReportingEnabled`, and `windowTitle` are mutated only on
///   `ptyQueue`. They are marked `nonisolated(unsafe)` to document this.
/// - PTY reads (`PTYProcess.onRead`) already run on `ptyQueue` because the
///   process is created with `readQueue: ptyQueue`.
/// - Every public entry point that touches the confined state enters
///   `ptyQueue` via `sync` (queries / snapshots) or `async` (mutations).
/// - Callbacks (`onScreenDirty`, `onTitleChanged`, etc.) fire on
///   `ptyQueue`. Callers that need a different execution context must hop
///   themselves (e.g., `Task { await someActor.handle(...) }`).
///
/// When adding new mutable fields or public APIs: keep everything that
/// touches the confined state behind `ptyQueue`, and do not expose raw
/// references to `screen`, `vtParser`, or `streamHandler`.
public final class TerminalCore: @unchecked Sendable {

    // Screen, parser, and handler are confined to ptyQueue.
    nonisolated(unsafe) private var screen: Screen
    nonisolated(unsafe) private var vtParser = VTParser()
    nonisolated(unsafe) private var streamHandler: StreamHandler
    nonisolated(unsafe) private var screenDirty = false

    /// Whether the application has subscribed to focus events via DECSET 1004.
    /// Confined to ptyQueue.
    nonisolated(unsafe) private var focusReportingEnabled = false

    /// Whether the application has enabled blinking cursor via DECSET 12.
    /// Confined to ptyQueue.
    nonisolated(unsafe) private(set) var cursorBlinkingEnabled = false

    /// Callback: blinking cursor mode (DECSET 12) toggled on/off.
    /// Fires on ptyQueue.
    public var onCursorBlinkingChanged: ((Bool) -> Void)?

    /// Whether the application has subscribed to color scheme reporting via DECSET 2031.
    /// Confined to ptyQueue.
    nonisolated(unsafe) private var colorSchemeReportingEnabled = false

    /// Title for dedup — confined to ptyQueue.
    nonisolated(unsafe) private var windowTitle: String = ""

    /// Text area pixel size for CSI 14 t responses — confined to ptyQueue.
    nonisolated(unsafe) private var pixelWidth: UInt32 = 0
    nonisolated(unsafe) private var pixelHeight: UInt32 = 0

    /// Dynamic colors set via OSC 10/11/12/13/14/17/19. Confined to ptyQueue.
    nonisolated(unsafe) private var dynamicForegroundColor: RGBColor?
    nonisolated(unsafe) private var dynamicBackgroundColor: RGBColor?
    nonisolated(unsafe) private var dynamicCursorColor: RGBColor?
    nonisolated(unsafe) private var dynamicPointerForegroundColor: RGBColor?
    nonisolated(unsafe) private var dynamicPointerBackgroundColor: RGBColor?
    nonisolated(unsafe) private var dynamicSelectionBackgroundColor: RGBColor?
    nonisolated(unsafe) private var dynamicSelectionForegroundColor: RGBColor?
    /// Palette color overrides set via OSC 4. Confined to ptyQueue.
    nonisolated(unsafe) private var paletteOverrides: [Int: RGBColor] = [:]

    private var ptyProcess: PTYProcess?

    private let ptyQueue: DispatchQueue

    /// Dispatch-specific key to detect when we are running on ptyQueue.
    /// Used by deinit to avoid deadlocking when the last strong reference
    /// is released by an event handler running on ptyQueue.
    private let ptyQueueKey = DispatchSpecificKey<Int>()

    /// Whether `stop()` has already been called. Used to prevent redundant
    /// cleanup and to let deinit know whether it needs to perform a fallback
    /// clear on ptyQueue.
    private let stoppedLock = NSLock()
    private var stopped = false

    // MARK: - Callbacks (fired on ptyQueue)

    /// Called when screen content becomes dirty.
    /// Only fires on the transition from clean to dirty; coalesced.
    public var onScreenDirty: (() -> Void)?

    /// Called whenever the terminal receives new content (e.g. PTY output).
    /// Unlike `onScreenDirty`, this fires for every update even if the screen
    /// is already dirty (e.g. background tabs). Use for activity indicators.
    public var onActivity: (() -> Void)?

    /// Called when the window title changes (OSC 0/2).
    public var onTitleChanged: ((String) -> Void)?

    /// Called when BEL (0x07) is received.
    public var onBell: (() -> Void)?

    /// Called when OSC 52 clipboard set request is received.
    public var onClipboardSet: ((String) -> Void)?

    /// Called when the child process exits with an exit code.
    public var onProcessExited: ((Int32) -> Void)?

    /// Called when the running command changes (shell integration OSC 7727).
    public var onRunningCommandChanged: ((String?) -> Void)?
    /// Called when a pane notification sequence is received (OSC 9 / 777 / 1337).
    public var onPaneNotification: ((String, String) -> Void)?
    /// Called when an unhandled control sequence is received.
    public var onUnhandledSequence: ((String) -> Void)?
    /// Called to query the current system color scheme (dark = true, light = false).
    /// Used by DSR 996/997 and mode 2031 immediate-report on enable.
    public var onColorSchemeQuery: (() -> Bool)?
    /// Called when a dynamic color changes via OSC 10/11.
    /// Parameters: (OSC number, new color).
    public var onDynamicColorChanged: ((Int, RGBColor?) -> Void)?
    /// Called to query the current default foreground/background color.
    /// Used by OSC 10/11 queries when no dynamic color has been set.
    /// Parameter: OSC number (10 = foreground, 11 = background).
    public var onDefaultColorQuery: ((Int) -> RGBColor?)?
    /// Called when the pointer shape changes via OSC 22.
    /// Parameter: cursor shape name (e.g. "default", "pointer", "text").
    public var onPointerShapeChanged: ((String) -> Void)?
    /// Called when a palette color changes via OSC 4.
    /// Parameters: (palette index, new color).
    public var onPaletteColorChanged: ((Int, RGBColor) -> Void)?
    /// Called to query the current palette color for OSC 4 queries.
    /// Used when no override has been set via OSC 4.
    /// Parameter: palette index (0-255).
    public var onPaletteColorQuery: ((Int) -> RGBColor?)?

    // MARK: - Init

    /// Create a new TerminalCore.
    ///
    /// - Parameters:
    ///   - columns: Initial terminal width in columns.
    ///   - rows: Initial terminal height in rows.
    ///   - maxScrollback: Maximum scrollback lines (default 10000).
    ///   - tabWidth: Tab stop width (default 8).
    ///   - ptyQueue: Dispatch queue for PTY reads and screen mutations.
    public init(
        columns: Int,
        rows: Int,
        maxScrollback: Int = 10000,
        tabWidth: Int = 8,
        ptyQueue: DispatchQueue? = nil
    ) {
        let queue = ptyQueue ?? DispatchQueue(
            label: "io.github.airead.tongyou.terminalcore.\(UUID().uuidString.prefix(8))",
            qos: .userInteractive
        )
        self.ptyQueue = queue
        queue.setSpecific(key: ptyQueueKey, value: 1)
        let screen = Screen(
            columns: columns,
            rows: rows,
            maxScrollback: maxScrollback,
            tabWidth: tabWidth
        )
        self.screen = screen
        self.streamHandler = StreamHandler(screen: screen)

        // Wire screen-state callbacks that don't depend on a running PTY so
        // they remain active in headless usage (tests, pre-start bootstrap).
        streamHandler.onFocusReportingChanged = { [weak self] enabled in
            self?.focusReportingEnabled = enabled
        }
        streamHandler.onBlinkingCursorChanged = { [weak self] enabled in
            self?.cursorBlinkingEnabled = enabled
            self?.onCursorBlinkingChanged?(enabled)
        }
        streamHandler.onColorSchemeReportingChanged = { [weak self] enabled in
            guard let self else { return }
            self.colorSchemeReportingEnabled = enabled
            // When mode 2031 is enabled, immediately report the current color scheme.
            if enabled, let isDark = self.onColorSchemeQuery?() {
                let ps = isDark ? 1 : 2
                let sequence = "\u{1B}[?997;\(ps)n"
                self.ptyProcess?.write(Data(sequence.utf8))
            }
        }
        streamHandler.onColorSchemeQuery = { [weak self] in
            self?.onColorSchemeQuery?() ?? false
        }
        streamHandler.onUnhandledSequence = { [weak self] message in
            Log.warning("Unhandled sequence: \(message)", category: .session)
            self?.onUnhandledSequence?(message)
        }
        streamHandler.onWindowPixelSizeRequest = { [weak self] in
            guard let self else { return (width: 0, height: 0) }
            return (width: self.pixelWidth, height: self.pixelHeight)
        }
        streamHandler.onDynamicColorQuery = { [weak self] oscNum in
            guard let self else { return nil }
            switch oscNum {
            case 10:
                return self.dynamicForegroundColor ?? self.onDefaultColorQuery?(10)
            case 11:
                return self.dynamicBackgroundColor ?? self.onDefaultColorQuery?(11)
            case 12:
                return self.dynamicCursorColor ?? self.onDefaultColorQuery?(12)
            case 13:
                return self.dynamicPointerForegroundColor ?? self.onDefaultColorQuery?(13)
            case 14:
                return self.dynamicPointerBackgroundColor ?? self.onDefaultColorQuery?(14)
            case 17:
                return self.dynamicSelectionBackgroundColor ?? self.onDefaultColorQuery?(17)
            case 19:
                return self.dynamicSelectionForegroundColor ?? self.onDefaultColorQuery?(19)
            default:
                return nil
            }
        }
        streamHandler.onDynamicColorSet = { [weak self] oscNum, color in
            guard let self else { return }
            switch oscNum {
            case 10:
                self.dynamicForegroundColor = color
            case 11:
                self.dynamicBackgroundColor = color
            case 12:
                self.dynamicCursorColor = color
            case 13:
                self.dynamicPointerForegroundColor = color
            case 14:
                self.dynamicPointerBackgroundColor = color
            case 17:
                self.dynamicSelectionBackgroundColor = color
            case 19:
                self.dynamicSelectionForegroundColor = color
            default:
                return
            }
            self.onDynamicColorChanged?(oscNum, color)
        }
        streamHandler.onDynamicColorReset = { [weak self] oscNum in
            guard let self else { return }
            switch oscNum {
            case 10:
                self.dynamicForegroundColor = nil
            case 11:
                self.dynamicBackgroundColor = nil
            case 12:
                self.dynamicCursorColor = nil
            case 13:
                self.dynamicPointerForegroundColor = nil
            case 14:
                self.dynamicPointerBackgroundColor = nil
            case 17:
                self.dynamicSelectionBackgroundColor = nil
            case 19:
                self.dynamicSelectionForegroundColor = nil
            default:
                return
            }
            let defaultColor = self.onDefaultColorQuery?(oscNum)
            self.onDynamicColorChanged?(oscNum, defaultColor)
        }
        streamHandler.onPointerShapeChanged = { [weak self] shape in
            self?.onPointerShapeChanged?(shape)
        }
        streamHandler.onPaletteColorQuery = { [weak self] index in
            guard let self else { return nil }
            return self.paletteOverrides[index] ?? self.onPaletteColorQuery?(index)
        }
        streamHandler.onPaletteColorSet = { [weak self] index, color in
            guard let self else { return }
            self.paletteOverrides[index] = color
            self.onPaletteColorChanged?(index, color)
        }
    }

    // MARK: - Lifecycle

    /// Start the PTY process with the default login shell.
    ///
    /// - Parameters:
    ///   - columns: Terminal width.
    ///   - rows: Terminal height.
    ///   - workingDirectory: Initial working directory for the shell.
    ///   - extraEnv: Optional environment overrides applied on top of the
    ///     default environment; later entries override earlier ones and
    ///     override any default-built value with the same key.
    public func start(columns: UInt16, rows: UInt16, workingDirectory: String,
                      extraEnv: [(String, String)] = []) throws {
        try startProcess { process in
            try process.start(
                columns: columns,
                rows: rows,
                workingDirectory: workingDirectory,
                extraEnv: extraEnv
            )
        }
    }

    /// Start the PTY process with a custom command.
    ///
    /// - Parameters:
    ///   - command: Executable path or name.
    ///   - arguments: Command arguments.
    ///   - columns: Terminal width.
    ///   - rows: Terminal height.
    ///   - workingDirectory: Initial working directory.
    ///   - extraEnv: Optional environment overrides (see shell variant).
    public func start(command: String, arguments: [String] = [],
                      columns: UInt16, rows: UInt16, workingDirectory: String,
                      extraEnv: [(String, String)] = []) throws {
        try startProcess { process in
            try process.start(
                command: command,
                arguments: arguments,
                columns: columns,
                rows: rows,
                workingDirectory: workingDirectory,
                extraEnv: extraEnv
            )
        }
    }

    /// Shared PTY setup: create process, wire callbacks, then call the launcher closure.
    private func startProcess(launcher: (PTYProcess) throws -> Void) rethrows {
        let process = PTYProcess(readQueue: ptyQueue)

        process.onRead = { [weak self] bytes in
            self?.processBytes(bytes)
        }

        process.onExit = { [weak self] exitCode in
            self?.onProcessExited?(exitCode)
        }

        // Wire StreamHandler callbacks (run on ptyQueue)
        streamHandler.onWriteBack = { [weak self] data in
            self?.ptyProcess?.write(data)
        }
        streamHandler.onTitleChanged = { [weak self] title in
            guard let self else { return }
            if title.isEmpty {
                let fallback = self.ptyProcess?.currentWorkingDirectory
                    .flatMap { URL(filePath: $0).lastPathComponent }
                    ?? ""
                guard !fallback.isEmpty, self.windowTitle != fallback else { return }
                self.windowTitle = fallback
                self.onTitleChanged?(fallback)
                return
            }
            guard self.windowTitle != title else { return }
            self.windowTitle = title
            self.onTitleChanged?(title)
        }
        streamHandler.onBell = { [weak self] in
            self?.onBell?()
        }
        streamHandler.onClipboardSet = { [weak self] text in
            self?.onClipboardSet?(text)
        }
        streamHandler.onRunningCommandChanged = { [weak self] cmd in
            self?.onRunningCommandChanged?(cmd)
        }
        streamHandler.onPaneNotification = { [weak self] title, body in
            self?.onPaneNotification?(title, body)
        }

        try launcher(process)
        ptyProcess = process
    }

    public func stop() {
        stoppedLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stoppedLock.unlock()
        guard !alreadyStopped else { return }

        // Clear callbacks synchronously on ptyQueue before tearing down the
        // PTY process. This prevents any in-flight handler from invoking
        // closures that capture resources we are about to release.
        ptyQueue.sync {
            clearStreamHandlerCallbacks()
        }

        ptyProcess?.stop()
        ptyProcess = nil
    }

    public var isRunning: Bool {
        ptyProcess != nil
    }

    // MARK: - Input

    public func write(_ data: Data) {
        ptyProcess?.write(data)
    }

    public func write(_ bytes: [UInt8]) {
        write(Data(bytes))
    }

    /// Report a focus change to the PTY if the application has subscribed
    /// via DECSET 1004. Writes `CSI I` (focus in) or `CSI O` (focus out).
    /// No-op when mode 1004 is not enabled.
    public func reportFocus(_ focused: Bool) {
        ptyQueue.async { [weak self] in
            guard let self, self.focusReportingEnabled else { return }
            let sequence: [UInt8] = focused
                ? [0x1B, 0x5B, 0x49]  // ESC [ I
                : [0x1B, 0x5B, 0x4F]  // ESC [ O
            self.ptyProcess?.write(Data(sequence))
        }
    }

    /// Test-only accessor for focus reporting state. Exposed via `@testable`
    /// so tests can verify DECSET 1004 toggles land on the core without
    /// launching a real PTY loopback.
    internal var isFocusReportingEnabledForTesting: Bool {
        ptyQueue.sync { focusReportingEnabled }
    }

    /// Report a color scheme change to the PTY if the application has subscribed
    /// via DECSET 2031. Writes `CSI ? 997 ; Ps n` where Ps=1 for dark, Ps=2 for light.
    /// No-op when mode 2031 is not enabled.
    public func reportColorScheme(_ isDark: Bool) {
        ptyQueue.async { [weak self] in
            guard let self, self.colorSchemeReportingEnabled else { return }
            let ps = isDark ? 1 : 2
            let sequence = "\u{1B}[?997;\(ps)n"
            self.ptyProcess?.write(Data(sequence.utf8))
        }
    }

    /// Test-only accessor for color scheme reporting state.
    internal var isColorSchemeReportingEnabledForTesting: Bool {
        ptyQueue.sync { colorSchemeReportingEnabled }
    }

    /// Test-only accessor for cursor blinking state (DECSET 12).
    internal var isCursorBlinkingEnabledForTesting: Bool {
        ptyQueue.sync { cursorBlinkingEnabled }
    }

    // MARK: - Synchronized Update (DECSET 2026)

    /// Whether this pane currently has an open BSU..ESU window. Checked by
    /// `SocketServer.performFlush` to decide whether to defer snapshot
    /// delivery.
    public var isSyncedUpdateActive: Bool {
        ptyQueue.sync { screen.syncedUpdateActive }
    }

    /// Auto-clear a synced-update window that has been open longer than
    /// `timeout`. Returns true iff this call cleared it. Called by
    /// `SocketServer.performFlush` as a safety net so a crashed TUI does
    /// not freeze the client view indefinitely.
    @discardableResult
    public func expireStaleSyncedUpdate(timeout: TimeInterval) -> Bool {
        ptyQueue.sync { screen.expireSyncedUpdateIfStale(timeout: timeout) }
    }

    /// Test-only byte feed that drives the same `processBytes` path used
    /// by the real PTY read callback, so tests can exercise state
    /// transitions without standing up a PTY subprocess.
    internal func feedBytesForTesting(_ bytes: [UInt8]) {
        ptyQueue.sync {
            bytes.withUnsafeBufferPointer { ptr in
                self.vtParser.feed(ptr) { action in
                    self.streamHandler.handle(action)
                }
            }
            self.streamHandler.flush()
            self.markScreenDirty()
        }
    }

    /// Encode a mouse event using the terminal's current tracking mode/format and write to PTY.
    public func handleMouseEvent(_ event: MouseEncoder.Event) {
        let (mode, format) = ptyQueue.sync {
            (streamHandler.modes.mouseTracking, streamHandler.modes.mouseFormat)
        }
        guard mode != .none else { return }
        guard let data = MouseEncoder.encode(
            event: event, trackingMode: mode, format: format
        ) else { return }
        ptyProcess?.write(data)
    }

    // MARK: - Resize

    public func resize(columns: UInt16, rows: UInt16,
                       pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        let cols = max(Screen.minColumns, Int(columns))
        let rows = max(Screen.minRows, Int(rows))
        nonisolated(unsafe) let process = ptyProcess

        ptyQueue.async { [weak self] in
            guard let self else { return }
            self.pixelWidth = UInt32(pixelWidth)
            self.pixelHeight = UInt32(pixelHeight)
            guard self.screen.columns != cols || self.screen.rows != rows else { return }
            self.screen.resize(columns: cols, rows: rows)
            self.markScreenDirty()

            process?.resize(
                columns: UInt16(clamping: cols),
                rows: UInt16(clamping: rows),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    // MARK: - Snapshot

    /// Returns a screen snapshot if content changed since the last call. Nil if idle.
    /// Thread-safe (synchronizes via ptyQueue).
    public func consumeSnapshot(selection: Selection? = nil, allowPartial: Bool = false) -> ScreenSnapshot? {
        guard screenDirty else { return nil }
        return ptyQueue.sync {
            screenDirty = false
            return screen.snapshot(selection: selection, allowPartial: allowPartial)
        }
    }

    /// Force a full snapshot regardless of dirty state (e.g., for client attach).
    /// Thread-safe.
    public func forceSnapshot() -> ScreenSnapshot {
        ptyQueue.sync {
            screenDirty = false
            return screen.snapshot()
        }
    }

    // MARK: - Viewport Scrolling

    /// Scroll the viewport by the given delta.
    /// Positive = up (older content), negative = down (newer content),
    /// `Int32.max` = jump to bottom.
    public func scrollViewport(delta: Int32) {
        guard delta != 0 else { return }
        ptyQueue.async { [weak self] in
            guard let self else { return }
            if delta == Int32.max {
                self.screen.scrollViewportToBottom()
            } else if delta > 0 {
                self.screen.scrollViewportUp(lines: Int(delta))
            } else {
                self.screen.scrollViewportDown(lines: Int(-delta))
            }
            self.markScreenDirty()
        }
    }

    // MARK: - Query

    /// Current terminal dimensions.
    public var columns: Int {
        ptyQueue.sync { screen.columns }
    }

    /// Current terminal dimensions.
    public var rows: Int {
        ptyQueue.sync { screen.rows }
    }

    public var currentWorkingDirectory: String? {
        ptyProcess?.currentWorkingDirectory
    }

    public var foregroundProcessName: String? {
        ptyProcess?.foregroundProcessName
    }

    public var appCursorMode: Bool {
        ptyQueue.sync { streamHandler.modes.isSet(.cursorKeys) }
    }

    public var appKeypadMode: Bool {
        ptyQueue.sync { streamHandler.modes.isSet(.keypadApplication) }
    }

    public var modifyOtherKeys: UInt8 {
        ptyQueue.sync { streamHandler.modes.modifyOtherKeys }
    }

    public var bracketedPasteMode: Bool {
        ptyQueue.sync { streamHandler.modes.isSet(.bracketedPaste) }
    }

    public var mouseTrackingMode: TerminalModes.MouseTrackingMode {
        ptyQueue.sync { streamHandler.modes.mouseTracking }
    }

    public var mouseFormat: TerminalModes.MouseFormat {
        ptyQueue.sync { streamHandler.modes.mouseFormat }
    }

    /// The hyperlink registry for OSC 8 support. Thread-safe access via ptyQueue.
    public var hyperlinkRegistry: HyperlinkRegistry {
        ptyQueue.sync { streamHandler.hyperlinkRegistry }
    }

    /// Number of scrollback lines above the visible screen.
    public var scrollbackCount: Int {
        ptyQueue.sync { screen.scrollbackCount }
    }

    /// Current viewport offset (0 = bottom, showing latest content).
    public var viewportOffset: Int {
        ptyQueue.sync { screen.viewportOffset }
    }

    /// Whether the viewport is scrolled up from the bottom.
    public var isScrolledUp: Bool {
        ptyQueue.sync { screen.isScrolledUp }
    }

    /// Read the Unicode scalar at an absolute line + column position. Thread-safe.
    public func codepoint(atAbsoluteLine line: Int, col: Int) -> Unicode.Scalar {
        ptyQueue.sync { screen.codepoint(atAbsoluteLine: line, col: col) }
    }

    /// Read a cell at the given viewport-relative position. Thread-safe.
    public func cell(at col: Int, row: Int) -> Cell {
        ptyQueue.sync { screen.cell(at: col, row: row) }
    }

    // MARK: - Screen Mutation

    /// Force a full redraw by marking all rows dirty. Thread-safe.
    public func forceFullRedraw() {
        ptyQueue.async { [weak self] in
            guard let self else { return }
            self.screen.forceFullRedraw()
            self.markScreenDirty()
        }
    }

    /// Set the viewport offset directly (for scrollToLine). Thread-safe.
    public func setViewportOffset(_ offset: Int) {
        ptyQueue.async { [weak self] in
            guard let self else { return }
            self.screen.setViewportOffset(offset)
            self.markScreenDirty()
        }
    }

    // MARK: - Search

    /// Search all terminal content for the given query. Thread-safe.
    public func search(query: String) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        return ptyQueue.sync { screen.search(query: query) }
    }

    /// Extract text from a selection range. Thread-safe.
    public func extractText(from selection: Selection) -> String {
        ptyQueue.sync { screen.extractText(from: selection) }
    }

    // MARK: - Private

    private func processBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        vtParser.feed(bytes) { [self] action in
            streamHandler.handle(action)
        }
        streamHandler.flush()
        markScreenDirty()
    }

    private func markScreenDirty() {
        let wasDirty = screenDirty
        screenDirty = true
        onActivity?()
        if !wasDirty {
            onScreenDirty?()
        }
    }

    deinit {
        // Callbacks should have been cleared by stop(). If stop() was already
        // called, there is nothing left to do.
        stoppedLock.lock()
        let alreadyStopped = stopped
        stoppedLock.unlock()
        guard !alreadyStopped else { return }

        // stop() was never called (e.g. the view was destroyed without an
        // orderly teardown). We must clear the callbacks, but we have to be
        // careful about which thread deinit is running on:
        //
        // • If we are on ptyQueue already (last strong reference released by an
        //   event handler), sync-ing to ptyQueue would deadlock. Clearing
        //   directly is safe because no other ptyQueue work can run concurrently
        //   with the current handler.
        //
        // • If we are on any other thread, we must sync to ptyQueue first so
        //   that any in-flight handler completes before we nil out the
        //   callbacks. Otherwise a handler that is mid-flight could read a
        //   partially-cleared or already-deallocated callback closure.
        if DispatchQueue.getSpecific(key: ptyQueueKey) == nil {
            ptyQueue.sync {
                clearStreamHandlerCallbacks()
            }
        } else {
            clearStreamHandlerCallbacks()
        }
    }

    /// Clear all streamHandler callbacks. Must only be called when no further
    /// ptyQueue work is expected (after stop() or in deinit).
    private func clearStreamHandlerCallbacks() {
        streamHandler.onWriteBack = nil
        streamHandler.onTitleChanged = nil
        streamHandler.onBell = nil
        streamHandler.onClipboardSet = nil
        streamHandler.onRunningCommandChanged = nil
        streamHandler.onPaneNotification = nil
        streamHandler.onFocusReportingChanged = nil
        streamHandler.onBlinkingCursorChanged = nil
        streamHandler.onColorSchemeReportingChanged = nil
        streamHandler.onColorSchemeQuery = nil
        streamHandler.onUnhandledSequence = nil
        streamHandler.onWindowPixelSizeRequest = nil
        streamHandler.onDynamicColorQuery = nil
        streamHandler.onDynamicColorSet = nil
        streamHandler.onDynamicColorReset = nil
        streamHandler.onPointerShapeChanged = nil
        streamHandler.onPaletteColorQuery = nil
        streamHandler.onPaletteColorSet = nil
    }
}
