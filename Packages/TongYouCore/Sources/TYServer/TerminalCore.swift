import Foundation
import TYTerminal
import TYPTY

/// Platform-independent terminal session core.
///
/// Manages PTY + VTParser + StreamHandler + Screen lifecycle.
/// No AppKit, no UI — pure backend logic suitable for both
/// the server daemon and headless testing.
///
/// Thread safety:
/// - PTY reads, VT parsing, and screen mutations happen on `ptyQueue`.
/// - Callbacks (`onScreenDirty`, `onTitleChanged`, etc.) fire on `ptyQueue`.
/// - `consumeSnapshot()` and query properties synchronize via `ptyQueue.sync`.
public final class TerminalCore: @unchecked Sendable {

    // Screen, parser, and handler are confined to ptyQueue.
    nonisolated(unsafe) private var screen: Screen
    nonisolated(unsafe) private var vtParser = VTParser()
    nonisolated(unsafe) private var streamHandler: StreamHandler
    nonisolated(unsafe) private var screenDirty = false

    /// Title for dedup — confined to ptyQueue.
    nonisolated(unsafe) private var windowTitle: String = ""

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
    }

    // MARK: - Lifecycle

    /// Start the PTY process with the default login shell.
    ///
    /// - Parameters:
    ///   - columns: Terminal width.
    ///   - rows: Terminal height.
    ///   - workingDirectory: Initial working directory for the shell.
    public func start(columns: UInt16, rows: UInt16, workingDirectory: String) throws {
        try startProcess { process in
            try process.start(
                columns: columns,
                rows: rows,
                workingDirectory: workingDirectory
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
    public func start(command: String, arguments: [String] = [],
                      columns: UInt16, rows: UInt16, workingDirectory: String) throws {
        try startProcess { process in
            try process.start(
                command: command,
                arguments: arguments,
                columns: columns,
                rows: rows,
                workingDirectory: workingDirectory
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

    public var bracketedPasteMode: Bool {
        ptyQueue.sync { streamHandler.modes.isSet(.bracketedPaste) }
    }

    public var mouseTrackingMode: TerminalModes.MouseTrackingMode {
        ptyQueue.sync { streamHandler.modes.mouseTracking }
    }

    public var mouseFormat: TerminalModes.MouseFormat {
        ptyQueue.sync { streamHandler.modes.mouseFormat }
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
