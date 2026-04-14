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
/// - `consumeSnapshot()` and `consumeDiff()` synchronize via `ptyQueue.sync`.
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
    var onScreenDirty: (() -> Void)?

    /// Called when the window title changes (OSC 0/2).
    var onTitleChanged: ((String) -> Void)?

    /// Called when BEL (0x07) is received.
    var onBell: (() -> Void)?

    /// Called when OSC 52 clipboard set request is received.
    var onClipboardSet: ((String) -> Void)?

    /// Called when the child process exits with an exit code.
    var onProcessExited: ((Int32) -> Void)?

    /// Called when the running command changes (shell integration OSC 7727).
    var onRunningCommandChanged: ((String?) -> Void)?

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

    /// Start the PTY process.
    ///
    /// - Parameters:
    ///   - columns: Terminal width.
    ///   - rows: Terminal height.
    ///   - workingDirectory: Initial working directory for the shell.
    public func start(columns: UInt16, rows: UInt16, workingDirectory: String) throws {
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

        try process.start(
            columns: columns,
            rows: rows,
            workingDirectory: workingDirectory
        )

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

    // MARK: - Resize

    public func resize(columns: UInt16, rows: UInt16) {
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
                rows: UInt16(clamping: rows)
            )
        }
    }

    // MARK: - Snapshot / Diff

    /// Returns a full screen snapshot if screen content changed since the last call.
    /// Returns nil if nothing changed. Thread-safe (synchronizes via ptyQueue).
    public func consumeSnapshot() -> ScreenSnapshot? {
        guard screenDirty else { return nil }
        return ptyQueue.sync {
            screenDirty = false
            return screen.snapshot()
        }
    }

    /// Build a ScreenDiff from the current dirty region.
    /// Returns nil if nothing changed. Thread-safe (synchronizes via ptyQueue).
    public func consumeDiff() -> (dirty: DirtyRegion, snapshot: ScreenSnapshot)? {
        guard screenDirty else { return nil }
        return ptyQueue.sync {
            screenDirty = false
            let snapshot = screen.snapshot()
            return (snapshot.dirtyRegion, snapshot)
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
