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

    /// Whether the application has subscribed to color scheme reporting via DECSET 2031.
    /// Confined to ptyQueue.
    nonisolated(unsafe) private var colorSchemeReportingEnabled = false

    /// Title for dedup — confined to ptyQueue.
    nonisolated(unsafe) private var windowTitle: String = ""

    /// Text area pixel size for CSI 14 t responses — confined to ptyQueue.
    nonisolated(unsafe) private var pixelWidth: UInt32 = 0
    nonisolated(unsafe) private var pixelHeight: UInt32 = 0

    private var ptyProcess: PTYProcess?

    private let ptyQueue: DispatchQueue

    // MARK: - Callbacks (fired on ptyQueue)

    /// Called when screen content becomes dirty.
    public var onScreenDirty: (() -> Void)?

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
    /// Used by DSR 997 and mode 2031 immediate-report on enable.
    public var onColorSchemeQuery: (() -> Bool)?

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
        if !wasDirty {
            onScreenDirty?()
        }
    }
}
