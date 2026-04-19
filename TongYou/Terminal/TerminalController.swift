import AppKit
import Foundation
import TYConfig
import TYTerminal
import TYServer

/// Coordinates a local terminal session with GUI-specific features.
///
/// Wraps `TerminalCore` for PTY + VT + Screen management, adding:
/// - Display-link debounce for efficient rendering
/// - Text selection with word-boundary expansion
/// - URL detection (on-demand when Cmd is held)
/// - Bell rate limiting
/// - Title change debouncing
/// - Search result focusing
final class TerminalController: TerminalControlling {

    private let core: TerminalCore

    // Set on ptyQueue (via core callback), read on main — atomic flag avoids per-read snapshot copies.
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

    /// Cached last successful core snapshot for selection-only updates.
    private var lastCoreSnapshot: ScreenSnapshot?

    /// Detected URLs in the current visible area (populated on demand when Cmd key is held).
    private(set) var detectedURLs: [DetectedURL] = []
    /// Track whether content changed to refresh URL detection while Cmd is held.
    nonisolated(unsafe) private var _contentGeneration: UInt64 = 0
    /// Monotonically-increasing generation counter for snapshot deduplication.
    var contentGeneration: UInt64 {
        _contentGeneration
    }

    /// Debounce work item for coalescing rapid display-link wakeups.
    nonisolated(unsafe) private var displayLinkDebounceWork: DispatchWorkItem?
    private var lastURLGeneration: UInt64 = 0
    /// Whether the Command key is currently held — drives on-demand URL detection.
    private var commandKeyHeld = false

    /// Bell rate limiting: at most one bell per second.
    nonisolated(unsafe) private var lastBellTime: CFAbsoluteTime = 0
    private static let bellMinInterval: CFAbsoluteTime = 1.0

    /// Current bell mode from configuration.
    private var bellMode: BellMode = .audible

    /// Called on the main thread when the child process exits with an exit code.
    var onProcessExited: ((Int32) -> Void)?

    /// Called on the main thread when the window title changes (OSC 0/2).
    var onTitleChanged: ((String) -> Void)?
    /// Called on the main thread when a pane notification sequence is received (OSC 9 / 777 / 1337).
    nonisolated(unsafe) var onPaneNotification: ((String, String) -> Void)?

    private(set) var isSuspended: Bool = false

    var dimensions: (columns: Int, rows: Int) {
        (core.columns, core.rows)
    }

    private var optionAsAlt: Bool

    init(columns: Int, rows: Int, config: Config = .default) {
        self.core = TerminalCore(
            columns: columns,
            rows: rows,
            maxScrollback: config.scrollbackLimit,
            tabWidth: config.tabWidth
        )
        self.bellMode = config.bell
        self.optionAsAlt = config.optionAsAlt

        wireCallbacks()
    }

    /// Wire TerminalCore callbacks to GUI-specific handlers.
    private func wireCallbacks() {
        core.onScreenDirty = { [weak self] in
            self?.handleScreenDirty()
        }
        core.onTitleChanged = { [weak self] title in
            guard let self else { return }
            self.windowTitle = title
            self.dispatchTitleToMain(title)
        }
        core.onBell = { [weak self] in
            self?.handleBell()
        }
        core.onClipboardSet = { text in
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
        core.onProcessExited = { [weak self] exitCode in
            self?.onProcessExited?(exitCode)
        }
        core.onRunningCommandChanged = { [weak self] cmd in
            self?.runningCommand = cmd
        }
        core.onPaneNotification = { [weak self] title, body in
            DispatchQueue.main.async { [weak self] in
                self?.onPaneNotification?(title, body)
            }
        }
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
        core.currentWorkingDirectory
    }

    /// Query the name of the foreground process in this terminal.
    var foregroundProcessName: String? {
        core.foregroundProcessName
    }

    private static let defaultWorkingDirectory: String =
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    func start(workingDirectory: String? = nil, command: String? = nil, arguments: [String] = [], extraEnv: [(String, String)] = []) {
        let cols = UInt16(clamping: core.columns)
        let rows = UInt16(clamping: core.rows)
        let dir = workingDirectory ?? Self.defaultWorkingDirectory

        do {
            if let command = command {
                try core.start(
                    command: command,
                    arguments: arguments,
                    columns: cols,
                    rows: rows,
                    workingDirectory: dir,
                    extraEnv: extraEnv
                )
            } else {
                try core.start(
                    columns: cols,
                    rows: rows,
                    workingDirectory: dir,
                    extraEnv: extraEnv
                )
            }
        } catch {
            print("Failed to start PTY: \(error)")
            return
        }
    }

    /// Start the PTY using a profile-resolved `StartupSnapshot`. A nil /
    /// empty `snapshot.command` selects the user's default login shell; a
    /// non-empty command runs that executable with `snapshot.args`.
    func start(snapshot: StartupSnapshot) {
        let commandOrNil = snapshot.command.flatMap { $0.isEmpty ? nil : $0 }
        start(
            workingDirectory: snapshot.cwd,
            command: commandOrNil,
            arguments: snapshot.args,
            extraEnv: snapshot.envTuples
        )
    }

    func stop() {
        core.stop()
    }

    func suspend() {
        isSuspended = true
    }

    func resume() {
        isSuspended = false
        handleScreenDirty()
    }

    // MARK: - Snapshot (called by display link on MainActor)

    /// Returns a snapshot if screen content changed since the last call. Nil if idle.
    func consumeSnapshot() -> ScreenSnapshot? {
        guard screenDirty else { return nil }
        screenDirty = false
        let sel = selection
        if let snapshot = core.consumeSnapshot(selection: sel, allowPartial: true) {
            lastCoreSnapshot = snapshot
            _contentGeneration &+= 1
            // Refresh URL detection only while Command key is held and content changed.
            if commandKeyHeld, _contentGeneration != lastURLGeneration {
                detectedURLs = URLDetector.detect(in: snapshot)
                lastURLGeneration = _contentGeneration
            }
            return snapshot
        }
        // Core screen content unchanged, but controller state (e.g. selection) changed.
        // Reuse the last snapshot with updated selection to avoid ptyQueue contention.
        guard var snapshot = lastCoreSnapshot else { return nil }
        snapshot.selection = sel
        _contentGeneration &+= 1
        return snapshot
    }

    // MARK: - Keyboard Input

    /// Dispatcher for real user keystrokes (keyDown / IME commit). When set
    /// by `SessionManager`, it routes each keystroke through the broadcast-
    /// input fan-out so selected sibling panes receive the same bytes.
    var onUserInputDispatched: (@MainActor (Data) -> Void)?

    func handleKeyDown(_ event: NSEvent) {
        let input = KeyEncoder.KeyInput(event: event)
        let options = KeyEncoder.Options(
            appCursorMode: core.appCursorMode,
            optionAsAlt: optionAsAlt
        )
        guard let data = KeyEncoder.encode(input, options: options) else { return }
        dispatchUserInput(data)
    }

    /// Send pre-composed text (e.g. from IME) directly to the PTY as UTF-8.
    func sendText(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        dispatchUserInput(data)
    }

    /// Send a pre-composed key event (e.g. from automation) to the PTY.
    /// Automation intentionally bypasses broadcast dispatch so scripted input
    /// only lands on the controller it targeted.
    func sendKey(_ input: KeyEncoder.KeyInput) {
        let options = KeyEncoder.Options(
            appCursorMode: core.appCursorMode,
            optionAsAlt: optionAsAlt
        )
        guard let data = KeyEncoder.encode(input, options: options) else { return }
        writeToPTY(data)
    }

    func receiveUserInput(_ data: Data) {
        writeToPTY(data)
    }

    private func dispatchUserInput(_ data: Data) {
        if let dispatcher = onUserInputDispatched {
            dispatcher(data)
        } else {
            writeToPTY(data)
        }
    }

    /// Clear selection, auto-scroll to bottom, and write data to the PTY.
    private func writeToPTY(_ data: Data) {
        selection = nil
        if core.isScrolledUp {
            core.scrollViewport(delta: Int32.max)
        }
        core.write(data)
    }

    // MARK: - Scrollback

    /// Scroll the viewport up (view older content).
    func scrollUp(lines: Int = 3) {
        core.scrollViewport(delta: Int32(clamping: lines))
    }

    /// Scroll the viewport down (view newer content).
    func scrollDown(lines: Int = 3) {
        core.scrollViewport(delta: -Int32(clamping: lines))
    }

    // MARK: - Selection

    /// Convert a viewport row to an absolute line number.
    private func viewportRowToAbsoluteLine(_ row: Int) -> Int {
        core.scrollbackCount - core.viewportOffset + row
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
            sel.end.col = core.columns - 1
        }

        selection = sel
        handleScreenDirty()
    }

    /// Update the selection end point (for drag).
    func updateSelection(col: Int, row: Int) {
        applySelectionEnd(col: col, absoluteLine: viewportRowToAbsoluteLine(row))
    }

    /// Update selection and auto-scroll when dragging outside viewport.
    func updateSelectionWithAutoScroll(col: Int, viewportRow: Int) {
        let visibleRows = core.rows

        let clampedRow: Int
        if viewportRow < 0 {
            core.scrollViewport(delta: Int32(clamping: min(-viewportRow, 3)))
            clampedRow = 0
        } else if viewportRow >= visibleRows {
            core.scrollViewport(delta: -Int32(clamping: min(viewportRow - visibleRows + 1, 3)))
            clampedRow = visibleRows - 1
        } else {
            clampedRow = viewportRow
        }

        applySelectionEnd(col: col, absoluteLine: viewportRowToAbsoluteLine(clampedRow))
    }

    /// Shared helper: set selection end-point and mark dirty.
    private func applySelectionEnd(col: Int, absoluteLine: Int) {
        guard var sel = selection else { return }
        sel.end = SelectionPoint(line: absoluteLine, col: col)
        if sel.mode == .line {
            sel.end.col = core.columns - 1
        }
        selection = sel
        handleScreenDirty()
    }

    /// Copy the selected text to the system clipboard.
    /// Returns true if text was copied.
    @discardableResult
    func copySelection() -> Bool {
        guard let sel = selection else { return false }
        let text = core.extractText(from: sel)
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        handleScreenDirty()
    }

    // MARK: - URL Actions

    /// Notify that Command key state changed. When pressed, triggers immediate URL detection;
    /// when released, clears cached results to free memory.
    func setCommandKeyHeld(_ held: Bool) {
        guard commandKeyHeld != held else { return }
        commandKeyHeld = held
        if held {
            let snapshot = core.forceSnapshot()
            detectedURLs = URLDetector.detect(in: snapshot)
            lastURLGeneration = _contentGeneration
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
            let scalar = core.codepoint(atAbsoluteLine: point.line, col: startCol - 1)
            guard Self.wordChars.contains(scalar) else { break }
            startCol -= 1
        }

        var endCol = point.col
        let maxCol = core.columns - 1
        while endCol < maxCol {
            let scalar = core.codepoint(atAbsoluteLine: point.line, col: endCol + 1)
            guard Self.wordChars.contains(scalar) else { break }
            endCol += 1
        }

        sel.start = SelectionPoint(line: point.line, col: startCol)
        sel.end = SelectionPoint(line: point.line, col: endCol)
    }

    // MARK: - Mouse Input

    /// Current mouse tracking mode, read by MetalView to decide event routing.
    var mouseTrackingMode: TerminalModes.MouseTrackingMode {
        core.mouseTrackingMode
    }

    /// Last reported cell for motion deduplication.
    private var lastMouseCell: (col: Int, row: Int)?

    func handleMouseEvent(_ event: MouseEncoder.Event) {
        let mode = core.mouseTrackingMode
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
            format: core.mouseFormat
        ) else { return }

        // Update dedup state
        if event.action == .motion {
            lastMouseCell = (event.col, event.row)
        } else {
            lastMouseCell = nil
        }

        core.write(data)
    }

    // MARK: - Resize

    func resize(columns newCols: Int, rows newRows: Int,
                cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        let cols = max(Screen.minColumns, newCols)
        let rows = max(Screen.minRows, newRows)
        core.resize(
            columns: UInt16(clamping: cols),
            rows: UInt16(clamping: rows),
            pixelWidth: UInt16(clamping: Int(cellWidth) * cols),
            pixelHeight: UInt16(clamping: Int(cellHeight) * rows)
        )
    }

    // MARK: - Bell

    /// Handle BEL character with rate limiting. Called on ptyQueue via core callback.
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
        let matches = core.search(query: query)
        guard !matches.isEmpty else {
            return SearchResult(matches: [], query: query, focusedIndex: nil)
        }
        // Focus the match nearest to the center of the current viewport.
        let viewportCenter = core.scrollbackCount - core.viewportOffset + core.rows / 2
        var result = SearchResult(matches: matches, query: query, focusedIndex: 0)
        result.focusNearest(toAbsoluteLine: viewportCenter)
        return result
    }

    /// Scroll the viewport so that the given absolute line is visible.
    func scrollToLine(_ absoluteLine: Int) {
        let sbCount = core.scrollbackCount
        let rows = core.rows
        // Calculate the viewport offset that places the target line near the center.
        let targetOffset = sbCount - absoluteLine + rows / 2
        let clamped = max(0, min(targetOffset, sbCount))
        guard core.viewportOffset != clamped else { return }
        core.setViewportOffset(clamped)
    }

    // MARK: - Paste

    func handlePaste(_ text: String) {
        guard !text.isEmpty else { return }
        var bytes = Array(text.utf8)

        for i in bytes.indices where unsafePasteBytes.contains(bytes[i]) {
            bytes[i] = 0x20
        }

        let bracketed = core.bracketedPasteMode
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

        writeToPTY(data)
    }

    // MARK: - Private: Screen Dirty Handling

    /// Called from TerminalCore's onScreenDirty callback (fires on ptyQueue).
    /// Coalesces rapid dirty marks into a single display-link wakeup.
    private func handleScreenDirty() {
        screenDirty = true
        guard !isSuspended else { return }

        // Coalesce rapid dirty marks into a single display-link wakeup.
        // If a wakeup is already scheduled, do not reschedule to avoid
        // pushing the render indefinitely while the user is scrolling.
        guard displayLinkDebounceWork == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayLinkDebounceWork = nil
            if self.screenDirty {
                self.onNeedsDisplay?()
            }
        }
        displayLinkDebounceWork = work
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - Title Debounce

    func forceFullRedraw() {
        core.forceFullRedraw()
    }

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
        // Schedule after debounce interval. Since we're called from ptyQueue callback,
        // dispatch to main with delay for debouncing.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.titleDebounceInterval,
            execute: work
        )
    }

}
