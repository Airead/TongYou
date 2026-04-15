import AppKit
import Foundation
import TYTerminal
import TYPTY

/// Coordinates PTY process, VT parser, stream handler, and screen buffer.
///
/// Concurrency model:
/// - PTY reads, VT parsing, and screen mutations happen on `ptyQueue` (background).
/// - A dirty flag is set on ptyQueue; the snapshot is taken only when consumed.
/// - `consumeSnapshot()` is called on MainActor by the display link.
final class TerminalController: TerminalControlling {

    private var ptyProcess: PTYProcess?

    // Screen, parser, and handler are confined to ptyQueue.
    nonisolated(unsafe) private var screen: Screen
    nonisolated(unsafe) private var vtParser = VTParser()
    nonisolated(unsafe) private var streamHandler: StreamHandler
    // Set on ptyQueue, read on main — atomic flag avoids per-read snapshot copies.
    nonisolated(unsafe) private var screenDirty = false

    /// Called when screen content becomes dirty. May be called from any thread.
    /// Used by MetalView to unpause the display link.
    nonisolated(unsafe) var onNeedsDisplay: (() -> Void)?

    /// Window title as reported by the running program via OSC 0/2.
    nonisolated(unsafe) private(set) var windowTitle: String = ""
    /// Pending debounce work item for title changes (runs on ptyQueue).
    nonisolated(unsafe) private var titleDebounceWork: DispatchWorkItem?

    /// Command currently running in the shell, reported via OSC 7727.
    /// nil means the shell is at a prompt.
    nonisolated(unsafe) private(set) var runningCommand: String?

    /// Active text selection (MainActor-only).
    private(set) var selection: Selection?

    /// Detected URLs in the current visible area (populated on demand when Cmd key is held).
    private(set) var detectedURLs: [DetectedURL] = []
    /// Track whether content changed to refresh URL detection while Cmd is held.
    nonisolated(unsafe) private var contentGeneration: UInt64 = 0
    private var lastURLGeneration: UInt64 = 0
    /// Whether the Command key is currently held — drives on-demand URL detection.
    private var commandKeyHeld = false

    /// Bell rate limiting: at most one bell per second.
    nonisolated(unsafe) private var lastBellTime: CFAbsoluteTime = 0
    private static let bellMinInterval: CFAbsoluteTime = 1.0

    /// Current bell mode from configuration.
    private var bellMode: BellMode = .audible

    /// Called on the main thread when the child process exits.
    var onProcessExited: (() -> Void)?

    /// Called on the main thread when the window title changes (OSC 0/2).
    var onTitleChanged: ((String) -> Void)?

    private(set) var isSuspended: Bool = false

    var dimensions: (columns: Int, rows: Int) {
        ptyQueue.sync { (screen.columns, screen.rows) }
    }

    private let ptyQueue = DispatchQueue(
        label: "io.github.airead.tongyou.pty.read",
        qos: .userInteractive
    )

    private var optionAsAlt: Bool

    init(columns: Int, rows: Int, config: Config = .default) {
        let screen = Screen(
            columns: columns,
            rows: rows,
            maxScrollback: config.scrollbackLimit,
            tabWidth: config.tabWidth
        )
        self.screen = screen
        self.streamHandler = StreamHandler(screen: screen)
        self.bellMode = config.bell
        self.optionAsAlt = config.optionAsAlt
    }

    /// Apply updated configuration (called from MetalView on hot reload).
    func applyConfig(_ config: Config) {
        bellMode = config.bell
        optionAsAlt = config.optionAsAlt
        // scrollbackLimit and tabWidth are set at Screen init and not changed at runtime
        // to avoid complexity with ring buffer resizing.
    }

    // MARK: - Lifecycle

    /// Query the current working directory of the child shell process.
    var currentWorkingDirectory: String? {
        ptyProcess?.currentWorkingDirectory
    }

    /// Query the name of the foreground process in this terminal.
    var foregroundProcessName: String? {
        ptyProcess?.foregroundProcessName
    }

    private static let defaultWorkingDirectory: String =
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    func start(workingDirectory: String? = nil, command: String? = nil, arguments: [String] = []) {
        let process = PTYProcess(readQueue: ptyQueue)

        process.onRead = { [weak self] bytes in
            self?.processBytes(bytes)
        }

        process.onExit = { [weak self] _ in
            self?.onProcessExited?()
        }

        // Wire StreamHandler callbacks (captured on ptyQueue)
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
                self.dispatchTitleToMain(fallback)
                return
            }

            guard self.windowTitle != title else { return }
            self.windowTitle = title
            self.dispatchTitleToMain(title)
        }
        streamHandler.onBell = { [weak self] in
            self?.handleBell()
        }
        streamHandler.onClipboardSet = { text in
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
        streamHandler.onRunningCommandChanged = { [weak self] cmd in
            self?.runningCommand = cmd
        }

        do {
            if let command = command {
                try process.start(
                    command: command,
                    arguments: arguments,
                    columns: UInt16(screen.columns),
                    rows: UInt16(screen.rows),
                    workingDirectory: workingDirectory ?? Self.defaultWorkingDirectory
                )
            } else {
                try process.start(
                    columns: UInt16(screen.columns),
                    rows: UInt16(screen.rows),
                    workingDirectory: workingDirectory ?? Self.defaultWorkingDirectory
                )
            }
        } catch {
            print("Failed to start PTY: \(error)")
            return
        }

        ptyProcess = process
    }

    func stop() {
        ptyProcess?.stop()
        ptyProcess = nil
    }

    func suspend() {
        isSuspended = true
    }

    func resume() {
        isSuspended = false
        screenDirty = true
        onNeedsDisplay?()
    }

    // MARK: - Snapshot (called by display link on MainActor)

    /// Returns a snapshot if screen content changed since the last call. Nil if idle.
    func consumeSnapshot() -> ScreenSnapshot? {
        guard screenDirty else { return nil }
        let sel = selection
        let (snapshot, gen): (ScreenSnapshot, UInt64) = ptyQueue.sync {
            screenDirty = false
            return (screen.snapshot(selection: sel), contentGeneration)
        }
        // Refresh URL detection only while Command key is held and content changed.
        if commandKeyHeld, gen != lastURLGeneration {
            detectedURLs = URLDetector.detect(in: snapshot)
            lastURLGeneration = gen
        }
        return snapshot
    }

    // MARK: - Keyboard Input

    func handleKeyDown(_ event: NSEvent) {
        let input = KeyEncoder.KeyInput(event: event)
        let options = KeyEncoder.Options(
            appCursorMode: streamHandler.modes.isSet(.cursorKeys),
            optionAsAlt: optionAsAlt
        )
        guard let data = KeyEncoder.encode(input, options: options) else { return }
        writeToPTY(data)
    }

    /// Send pre-composed text (e.g. from IME) directly to the PTY as UTF-8.
    func sendText(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        writeToPTY(data)
    }

    /// Clear selection, auto-scroll to bottom, and write data to the PTY.
    private func writeToPTY(_ data: Data) {
        selection = nil
        ptyQueue.async { [weak self] in
            guard let self else { return }
            if self.screen.isScrolledUp {
                self.screen.scrollViewportToBottom()
                self.markScreenDirty()
            }
        }
        ptyProcess?.write(data)
    }

    // MARK: - Scrollback

    /// Scroll the viewport up (view older content).
    func scrollUp(lines: Int = 3) {
        // Don't scroll in alt screen or when mouse tracking is active for scroll events
        ptyQueue.async { [weak self] in
            guard let self else { return }
            self.screen.scrollViewportUp(lines: lines)
            self.markScreenDirty()
        }
    }

    /// Scroll the viewport down (view newer content).
    func scrollDown(lines: Int = 3) {
        ptyQueue.async { [weak self] in
            guard let self else { return }
            self.screen.scrollViewportDown(lines: lines)
            self.markScreenDirty()
        }
    }

    // MARK: - Selection

    /// Convert a viewport row to an absolute line number.
    private func viewportRowToAbsoluteLine(_ row: Int) -> Int {
        screen.scrollbackCount - screen.viewportOffset + row
    }

    /// Start a new selection at the given viewport position.
    func startSelection(col: Int, row: Int, mode: SelectionMode = .character) {
        let line = viewportRowToAbsoluteLine(row)
        let point = SelectionPoint(line: line, col: col)
        var sel = Selection(start: point, end: point, mode: mode)

        if mode == .word {
            expandWordSelection(&sel, at: point)
        } else if mode == .line {
            sel.start.col = 0
            sel.end.col = screen.columns - 1
        }

        selection = sel
        markScreenDirty()
    }

    /// Update the selection end point (for drag).
    func updateSelection(col: Int, row: Int) {
        applySelectionEnd(col: col, absoluteLine: viewportRowToAbsoluteLine(row))
    }

    /// Update selection and auto-scroll when dragging outside viewport.
    func updateSelectionWithAutoScroll(col: Int, viewportRow: Int) {
        ptyQueue.async { [weak self] in
            guard let self else { return }
            let visibleRows = self.screen.rows

            let clampedRow: Int
            if viewportRow < 0 {
                self.screen.scrollViewportUp(lines: min(-viewportRow, 3))
                clampedRow = 0
            } else if viewportRow >= visibleRows {
                self.screen.scrollViewportDown(lines: min(viewportRow - visibleRows + 1, 3))
                clampedRow = visibleRows - 1
            } else {
                clampedRow = viewportRow
            }

            self.applySelectionEnd(col: col, absoluteLine: self.viewportRowToAbsoluteLine(clampedRow))
        }
    }

    /// Shared helper: set selection end-point and mark dirty.
    private func applySelectionEnd(col: Int, absoluteLine: Int) {
        guard var sel = selection else { return }
        sel.end = SelectionPoint(line: absoluteLine, col: col)
        if sel.mode == .line {
            sel.end.col = screen.columns - 1
        }
        selection = sel
        markScreenDirty()
    }

    /// Copy the selected text to the system clipboard.
    /// Returns true if text was copied.
    @discardableResult
    func copySelection() -> Bool {
        guard let sel = selection else { return false }
        let text = ptyQueue.sync { screen.extractText(from: sel) }
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    // MARK: - URL Actions

    /// Notify that Command key state changed. When pressed, triggers immediate URL detection;
    /// when released, clears cached results to free memory.
    func setCommandKeyHeld(_ held: Bool) {
        guard commandKeyHeld != held else { return }
        commandKeyHeld = held
        if held {
            let sel = selection
            let (snapshot, gen): (ScreenSnapshot, UInt64) = ptyQueue.sync {
                (screen.snapshot(selection: sel), contentGeneration)
            }
            detectedURLs = URLDetector.detect(in: snapshot)
            lastURLGeneration = gen
        } else {
            detectedURLs = []
        }
    }

    /// Try to open the URL at the given viewport position.
    /// Returns true if a URL was found and opened.
    @discardableResult
    func openURL(at row: Int, col: Int) -> Bool {
        guard let detected = URLDetector.url(at: row, col: col, in: detectedURLs),
              let url = URL(string: detected.url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Get the URL at the given viewport position, if any.
    func urlAt(row: Int, col: Int) -> DetectedURL? {
        URLDetector.url(at: row, col: col, in: detectedURLs)
    }

    // MARK: - Private: Word Boundary Detection

    private static let wordChars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-./:~"))

    private func expandWordSelection(_ sel: inout Selection, at point: SelectionPoint) {
        var startCol = point.col
        while startCol > 0 {
            let scalar = screen.codepoint(atAbsoluteLine: point.line, col: startCol - 1)
            guard Self.wordChars.contains(scalar) else { break }
            startCol -= 1
        }

        var endCol = point.col
        let maxCol = screen.columns - 1
        while endCol < maxCol {
            let scalar = screen.codepoint(atAbsoluteLine: point.line, col: endCol + 1)
            guard Self.wordChars.contains(scalar) else { break }
            endCol += 1
        }

        sel.start = SelectionPoint(line: point.line, col: startCol)
        sel.end = SelectionPoint(line: point.line, col: endCol)
    }

    // MARK: - Mouse Input

    /// Current mouse tracking mode, read by MetalView to decide event routing.
    var mouseTrackingMode: TerminalModes.MouseTrackingMode {
        streamHandler.modes.mouseTracking
    }

    /// Last reported cell for motion deduplication.
    private var lastMouseCell: (col: Int, row: Int)?

    func handleMouseEvent(_ event: MouseEncoder.Event) {
        let mode = streamHandler.modes.mouseTracking
        guard mode != .none else { return }

        // Motion deduplication: don't report same cell twice
        if event.action == .motion {
            if let last = lastMouseCell, last.col == event.col, last.row == event.row {
                return
            }
        }

        guard let data = MouseEncoder.encode(
            event: event,
            trackingMode: mode,
            format: streamHandler.modes.mouseFormat
        ) else { return }

        // Update dedup state
        if event.action == .motion {
            lastMouseCell = (event.col, event.row)
        } else {
            lastMouseCell = nil
        }

        ptyProcess?.write(data)
    }

    // MARK: - Resize

    func resize(columns newCols: Int, rows newRows: Int,
                cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        let cols = max(Screen.minColumns, newCols)
        let rows = max(Screen.minRows, newRows)
        let process = ptyProcess  // Capture on MainActor before dispatching

        ptyQueue.async { [weak self] in
            guard let self else { return }
            guard self.screen.columns != cols || self.screen.rows != rows else { return }
            self.screen.resize(columns: cols, rows: rows)
            self.markScreenDirty()

            process?.resize(
                columns: UInt16(clamping: cols),
                rows: UInt16(clamping: rows),
                pixelWidth: UInt16(clamping: Int(cellWidth) * cols),
                pixelHeight: UInt16(clamping: Int(cellHeight) * rows)
            )
        }
    }

    // MARK: - Bell

    /// Handle BEL character with rate limiting. Called on ptyQueue.
    private func handleBell() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBellTime >= Self.bellMinInterval else { return }
        lastBellTime = now
        let mode = bellMode
        DispatchQueue.main.async {
            switch mode {
            case .audible:
                NSSound.beep()
            case .visual:
                // Visual bell will be implemented in the renderer (flash overlay)
                break
            case .none:
                break
            }
        }
    }

    // MARK: - Search

    /// Search all terminal content for the given query. Runs on ptyQueue.
    /// Returns a SearchResult with matches and the focused index nearest to the viewport center.
    func search(query: String) -> SearchResult {
        guard !query.isEmpty else { return .empty }
        let matches = ptyQueue.sync { screen.search(query: query) }
        guard !matches.isEmpty else {
            return SearchResult(matches: [], query: query, focusedIndex: nil)
        }
        // Focus the match nearest to the center of the current viewport.
        let viewportCenter = screen.scrollbackCount - screen.viewportOffset + screen.rows / 2
        var result = SearchResult(matches: matches, query: query, focusedIndex: 0)
        result.focusNearest(toAbsoluteLine: viewportCenter)
        return result
    }

    /// Scroll the viewport so that the given absolute line is visible.
    func scrollToLine(_ absoluteLine: Int) {
        ptyQueue.async { [weak self] in
            guard let self else { return }
            let sbCount = self.screen.scrollbackCount
            let rows = self.screen.rows
            // Calculate the viewport offset that places the target line near the center.
            let targetOffset = sbCount - absoluteLine + rows / 2
            let clamped = max(0, min(targetOffset, sbCount))
            guard self.screen.viewportOffset != clamped else { return }
            self.screen.setViewportOffset(clamped)
            self.markScreenDirty()
        }
    }

    // MARK: - Paste

    func handlePaste(_ text: String) {
        guard !text.isEmpty else { return }
        var bytes = Array(text.utf8)

        for i in bytes.indices where unsafePasteBytes.contains(bytes[i]) {
            bytes[i] = 0x20
        }

        let bracketed = streamHandler.modes.isSet(.bracketedPaste)
        var data = Data()

        if bracketed {
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
            data.append(contentsOf: bytes)
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~
        } else {
            // Non-bracketed: replace \n with \r
            for i in bytes.indices where bytes[i] == 0x0A {
                bytes[i] = 0x0D
            }
            data.append(contentsOf: bytes)
        }

        ptyProcess?.write(data)
    }

    // MARK: - Private: Byte Processing (runs on ptyQueue)

    private func processBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        vtParser.feed(bytes) { [self] action in
            streamHandler.handle(action)
        }
        streamHandler.flush()
        contentGeneration &+= 1
        markScreenDirty()
    }

    /// Set the dirty flag and notify the display to wake up.
    /// Safe to call from any thread.
    private func markScreenDirty() {
        let wasDirty = screenDirty
        screenDirty = true
        if !wasDirty && !isSuspended {
            onNeedsDisplay?()
        }
    }

    // MARK: - Title Debounce

    /// Debounce interval for coalescing rapid title changes (seconds).
    private static let titleDebounceInterval: TimeInterval = 0.075

    /// Dispatch a title change to the main thread with debouncing.
    /// Called on ptyQueue.
    private func dispatchTitleToMain(_ title: String) {
        titleDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.titleDebounceWork = nil
            DispatchQueue.main.async {
                self.onTitleChanged?(title)
            }
        }
        titleDebounceWork = work
        ptyQueue.asyncAfter(
            deadline: .now() + Self.titleDebounceInterval,
            execute: work
        )
    }

}
