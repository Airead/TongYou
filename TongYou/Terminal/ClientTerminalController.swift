import AppKit
import Foundation
import TYClient
import TYProtocol
import TYTerminal

/// Terminal controller backed by a remote tyd session.
///
/// Maintains a local `ScreenReplica` updated by server diffs/snapshots.
/// User input is encoded locally and sent to the server via the socket.
/// Provides the same `TerminalControlling` interface as `TerminalController`.
final class ClientTerminalController: TerminalControlling {

    private let remoteClient: RemoteSessionClient
    private let sessionID: SessionID
    private let paneID: PaneID
    private let screenReplica: ScreenReplica

    private(set) var selection: Selection?
    private(set) var detectedURLs: [DetectedURL] = []
    private var commandKeyHeld = false
    private var lastURLGeneration: UInt64 = 0
    private var contentGeneration: UInt64 = 0

    private(set) var windowTitle: String = ""
    private(set) var runningCommand: String?
    private var optionAsAlt: Bool = false

    var onNeedsDisplay: (() -> Void)?
    var onProcessExited: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?

    init(
        remoteClient: RemoteSessionClient,
        sessionID: SessionID,
        paneID: PaneID
    ) {
        self.remoteClient = remoteClient
        self.sessionID = sessionID
        self.paneID = paneID
        self.screenReplica = remoteClient.replica(for: paneID)
    }

    // MARK: - Snapshot

    func consumeSnapshot() -> ScreenSnapshot? {
        let sel = selection
        guard let snapshot = screenReplica.consumeSnapshot(selection: sel) else { return nil }

        if commandKeyHeld {
            let gen = contentGeneration
            if gen != lastURLGeneration {
                detectedURLs = URLDetector.detect(in: snapshot)
                lastURLGeneration = gen
            }
        }
        return snapshot
    }

    // MARK: - Keyboard & Text Input

    func handleKeyDown(_ event: NSEvent) {
        let input = KeyEncoder.KeyInput(event: event)
        let options = KeyEncoder.Options(
            appCursorMode: false,
            optionAsAlt: optionAsAlt
        )
        guard let data = KeyEncoder.encode(input, options: options) else { return }
        selection = nil
        remoteClient.sendInput(
            sessionID: sessionID,
            paneID: paneID,
            data: Array(data)
        )
    }

    func sendText(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        selection = nil
        remoteClient.sendInput(
            sessionID: sessionID,
            paneID: paneID,
            data: Array(data)
        )
    }

    // MARK: - Scrollback

    func scrollUp(lines: Int = 3) {
        // No-op: remote screen replica has no scrollback buffer.
    }

    func scrollDown(lines: Int = 3) {
        // No-op: remote screen replica has no scrollback buffer.
    }

    // MARK: - Selection (operates on local replica)

    func startSelection(col: Int, row: Int, mode: SelectionMode = .character) {
        let point = SelectionPoint(line: row, col: col)
        var sel = Selection(start: point, end: point, mode: mode)

        if mode == .line {
            sel.start.col = 0
            sel.end.col = screenReplica.columns - 1
        }

        selection = sel
        screenReplica.markDirty()
        onNeedsDisplay?()
    }

    func updateSelection(col: Int, row: Int) {
        guard var sel = selection else { return }
        sel.end = SelectionPoint(line: row, col: col)

        if sel.mode == .line {
            sel.end.col = screenReplica.columns - 1
        }

        selection = sel
        screenReplica.markDirty()
        onNeedsDisplay?()
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let sel = selection else { return false }
        let snapshot = screenReplica.forceSnapshot(selection: sel)
        let text = snapshot.extractText(from: sel)
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    // MARK: - URL Detection

    func setCommandKeyHeld(_ held: Bool) {
        guard commandKeyHeld != held else { return }
        commandKeyHeld = held
        if held {
            let snapshot = screenReplica.forceSnapshot(selection: selection)
            detectedURLs = URLDetector.detect(in: snapshot)
            lastURLGeneration = contentGeneration
        } else {
            detectedURLs = []
        }
    }

    @discardableResult
    func openURL(at row: Int, col: Int) -> Bool {
        guard let detected = URLDetector.url(at: row, col: col, in: detectedURLs),
              let url = URL(string: detected.url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    func urlAt(row: Int, col: Int) -> DetectedURL? {
        URLDetector.url(at: row, col: col, in: detectedURLs)
    }

    // MARK: - Mouse

    var mouseTrackingMode: TerminalModes.MouseTrackingMode { .none }

    func handleMouseEvent(_ event: MouseEncoder.Event) {
        // Mouse tracking for remote sessions would require server-side mode tracking.
        // For now, not supported.
    }

    // MARK: - Resize

    func resize(columns: Int, rows: Int, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        let cols = max(Screen.minColumns, columns)
        let rows = max(Screen.minRows, rows)
        remoteClient.resizePane(
            sessionID: sessionID,
            paneID: paneID,
            cols: UInt16(clamping: cols),
            rows: UInt16(clamping: rows)
        )
    }

    // MARK: - Search (not supported for remote sessions)

    func search(query: String) -> SearchResult {
        .empty
    }

    func scrollToLine(_ absoluteLine: Int) {
        // Not applicable for remote sessions without server-side scrollback support.
    }

    // MARK: - Paste

    func handlePaste(_ text: String) {
        guard !text.isEmpty else { return }
        var bytes = Array(text.utf8)

        for i in bytes.indices where unsafePasteBytes.contains(bytes[i]) {
            bytes[i] = 0x20
        }

        remoteClient.sendInput(
            sessionID: sessionID,
            paneID: paneID,
            data: bytes
        )
    }

    // MARK: - Config

    func applyConfig(_ config: Config) {
        optionAsAlt = config.optionAsAlt
    }

    // MARK: - State

    var currentWorkingDirectory: String? { nil }
    var foregroundProcessName: String? { nil }

    // MARK: - Lifecycle

    func stop() {
        remoteClient.removeReplica(for: paneID)
    }

    // MARK: - Server Update Callbacks

    /// Called by the session manager when screen content is updated from the server.
    func handleScreenUpdated() {
        contentGeneration &+= 1
        onNeedsDisplay?()
    }

    /// Called when the server reports a title change for this pane.
    func handleTitleChanged(_ title: String) {
        windowTitle = title
        onTitleChanged?(title)
    }

    /// Called when the server reports the pane's process exited.
    func handleProcessExited() {
        onProcessExited?()
    }

}
