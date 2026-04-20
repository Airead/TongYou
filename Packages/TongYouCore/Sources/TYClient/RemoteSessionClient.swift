import Foundation
import TYConfig
import TYProtocol
import TYTerminal

/// Manages the client-side view of all remote sessions from a tongyou server.
///
/// Subscribes to session lifecycle events and screen updates, maintaining
/// a `ScreenReplica` for each attached pane. The GUI layer observes changes
/// via callbacks to update its SessionManager and MetalViews.
public final class RemoteSessionClient: @unchecked Sendable {

    private let connectionManager: TYDConnectionManager
    private var connection: TYDConnection?

    /// Screen replicas indexed by PaneID.
    private var replicas: [PaneID: ScreenReplica] = [:]
    private let replicaLock = NSLock()

    /// Last cursor/geometry stamped into a `[RECV]` cursorTrace log per pane.
    /// Temporary — remove with the cursorTrace category.
    private var lastCursorTrace: [PaneID: (row: Int, col: Int, cols: Int, rows: Int, vis: Bool)] = [:]
    private let cursorTraceLock = NSLock()

    /// Sink for `[RECV]` cursorTrace messages. The GUI wires this to `GUILog`
    /// so client-side receive logs land in the same file as renderer logs.
    /// The server `PaneID` is passed separately so the GUI can translate it
    /// into the client-side local pane UUID for correlation with `[DRAW]` logs.
    /// Temporary — remove with the cursorTrace category.
    public var cursorTraceHandler: ((String, PaneID) -> Void)?

    // MARK: - Callbacks (dispatched to main queue)

    /// Called when the session list is received from the server.
    public var onSessionList: (([SessionInfo]) -> Void)?

    /// Called when a new session is created on the server.
    public var onSessionCreated: ((SessionInfo) -> Void)?

    /// Called when a session is closed on the server.
    public var onSessionClosed: ((SessionID) -> Void)?

    /// Called when a pane's screen content is updated (full or diff).
    /// The ScreenReplica has already been updated; the callback provides
    /// the pane ID so the GUI can wake the display link.
    public var onScreenUpdated: ((SessionID, PaneID) -> Void)?

    /// Called when a pane's title changes.
    public var onTitleChanged: ((SessionID, PaneID, String) -> Void)?

    /// Called when a pane's working directory changes.
    public var onCwdChanged: ((SessionID, PaneID, String) -> Void)?

    /// Called when a bell is received.
    public var onBell: ((SessionID, PaneID) -> Void)?

    /// Called when a pane's process exits.
    public var onPaneExited: ((SessionID, PaneID, Int32) -> Void)?

    /// Called when a session's layout changes (full tab list + active index).
    public var onLayoutUpdate: ((SessionInfo) -> Void)?

    /// Called when the server sets the clipboard.
    public var onClipboardSet: ((String) -> Void)?

    /// Called when the connection to the server is established.
    public var onConnected: (() -> Void)?

    /// Called when the connection to the server is lost.
    public var onDisconnected: (() -> Void)?

    public init(connectionManager: TYDConnectionManager) {
        self.connectionManager = connectionManager
    }

    // MARK: - Connection

    /// Connect to the server and request the session list.
    public func connect() throws {
        let conn = try connectionManager.connect()
        wireConnection(conn)
    }

    /// Attach a pre-established connection (for when connect was done off-thread).
    public func attachConnection(_ conn: TYDConnection) {
        wireConnection(conn)
    }

    private func wireConnection(_ conn: TYDConnection) {
        connection = conn

        conn.onMessage = { [weak self] message in
            self?.handleServerMessage(message)
        }

        connectionManager.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.onDisconnected?()
            }
        }

        conn.send(.listSessions)

        DispatchQueue.main.async { [weak self] in
            self?.onConnected?()
        }
    }

    /// Disconnect from the server.
    public func disconnect() {
        connectionManager.disconnect()
        connection = nil
        replicaLock.lock()
        replicas.removeAll()
        replicaLock.unlock()
        cursorTraceLock.lock()
        lastCursorTrace.removeAll()
        cursorTraceLock.unlock()
    }

    public var isConnected: Bool {
        connectionManager.isConnected
    }

    // MARK: - Session Operations

    /// Request the current session list from the server.
    public func requestSessionList() {
        connection?.send(.listSessions)
    }

    /// Ask the server to create a new session.
    public func createSession(name: String? = nil) {
        connection?.send(.createSession(name: name))
    }

    /// Attach to an existing server session (starts receiving screen updates).
    public func attachSession(_ sessionID: SessionID) {
        connection?.send(.attachSession(sessionID))
    }

    /// Detach from a server session (stops receiving screen updates).
    public func detachSession(_ sessionID: SessionID) {
        connection?.send(.detachSession(sessionID))
    }

    /// Ask the server to close a session.
    public func closeSession(_ sessionID: SessionID) {
        connection?.send(.closeSession(sessionID))
    }

    /// Ask the server to rename a session.
    public func renameSession(_ sessionID: SessionID, name: String) {
        connection?.send(.renameSession(sessionID, name: name))
    }

    // MARK: - Terminal I/O

    /// Send terminal input to a specific pane.
    public func sendInput(sessionID: SessionID, paneID: PaneID, data: [UInt8]) {
        connection?.send(.input(sessionID, paneID, data))
    }

    /// Send a paste payload to a pane. The server applies bracketed-paste
    /// wrapping (mode 2004) or `\n` → `\r` conversion based on the pane's
    /// current terminal modes — the client does not replicate that state.
    public func sendPaste(sessionID: SessionID, paneID: PaneID, data: [UInt8]) {
        connection?.send(.paste(sessionID, paneID, data))
    }

    /// Resize a pane on the server.
    public func resizePane(sessionID: SessionID, paneID: PaneID, cols: UInt16, rows: UInt16) {
        connection?.send(.resize(sessionID, paneID, cols: cols, rows: rows))
    }

    /// Scroll the viewport for a pane on the server.
    /// Positive delta = up (older), negative = down (newer), Int32.max = jump to bottom.
    public func scrollViewport(sessionID: SessionID, paneID: PaneID, delta: Int32) {
        connection?.send(.scrollViewport(sessionID, paneID, delta: delta))
    }

    /// Ask the server to extract text from a selection. Server replies with `.clipboardSet`.
    public func extractSelection(sessionID: SessionID, paneID: PaneID, selection: Selection) {
        connection?.send(.extractSelection(sessionID, paneID, selection))
    }

    /// Send a mouse event to the server for encoding and PTY delivery.
    public func sendMouseEvent(sessionID: SessionID, paneID: PaneID, event: MouseEncoder.Event) {
        connection?.send(.mouseEvent(sessionID, paneID, event))
    }

    // MARK: - Tab/Pane Operations

    public func createTab(
        sessionID: SessionID,
        profileID: String?,
        snapshot: StartupSnapshot?,
        variables: [String: String] = [:]
    ) {
        connection?.send(.createTab(
            sessionID, profileID: profileID, snapshot: snapshot, variables: variables
        ))
    }

    /// Ship a batch `createTabWithGridPanes` request. The server spawns
    /// every pane in one go, arranges them in a canonical grid, and emits
    /// a single `layoutUpdate` — used by the command palette's batch SSH
    /// path to avoid per-split resize churn on the remote side.
    public func createTabWithGridPanes(
        sessionID: SessionID,
        specs: [GridPaneSpec]
    ) {
        connection?.send(.createTabWithGridPanes(sessionID, specs))
    }

    public func closeTab(sessionID: SessionID, tabID: TabID) {
        connection?.send(.closeTab(sessionID, tabID))
    }

    public func splitPane(
        sessionID: SessionID,
        paneID: PaneID,
        direction: SplitDirection,
        profileID: String?,
        snapshot: StartupSnapshot?,
        variables: [String: String] = [:]
    ) {
        connection?.send(.splitPane(
            sessionID, paneID, direction,
            profileID: profileID,
            snapshot: snapshot,
            variables: variables
        ))
    }

    public func closePane(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.closePane(sessionID, paneID))
    }

    public func focusPane(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.focusPane(sessionID, paneID))
    }

    /// Report a focus in/out transition for `paneID`. The server forwards
    /// this to the backing PTY only if the running app has enabled DECSET
    /// 1004 focus events.
    public func reportPaneFocus(sessionID: SessionID, paneID: PaneID, focused: Bool) {
        connection?.send(.paneFocusEvent(sessionID, paneID, focused: focused))
    }

    /// Diagnostic — ask the server to re-emit a full screen snapshot for
    /// `paneID`. No PTY side-effect; used to triage the split-pane
    /// misalignment bug. Temporary.
    public func refreshPane(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.refreshPane(sessionID, paneID))
    }

    public func selectTab(sessionID: SessionID, tabIndex: UInt16) {
        connection?.send(.selectTab(sessionID, tabIndex: tabIndex))
    }

    /// Ask the server to adjust a split ratio. The pane whose position in
    /// the tree directly identifies the parent split receives `ratio` as
    /// its share of that split.
    public func setSplitRatio(sessionID: SessionID, paneID: PaneID, ratio: Float) {
        connection?.send(.setSplitRatio(sessionID, paneID, ratio: ratio))
    }

    /// Ask the server to relocate `sourcePaneID` to the given `side` of
    /// `targetPaneID`. The server updates the tree and broadcasts a
    /// `layoutUpdate`; focus stays on the source pane because its UUID
    /// survives the move (plan §P4.3).
    public func movePane(
        sessionID: SessionID,
        sourcePaneID: PaneID,
        targetPaneID: PaneID,
        side: FocusDirection
    ) {
        connection?.send(.movePane(
            sessionID,
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            side: side
        ))
    }

    /// Ask the server to rewrite the tab that owns `paneID` into a single
    /// flat container using `kind` (plan §P4.5). Any prior nesting is
    /// flattened; every leaf ends up as a direct child with equal
    /// weights. `paneID` only identifies the target tab — the request is
    /// a whole-tree replacement, not a nested-container mutation. The
    /// server broadcasts `layoutUpdate` on change and treats a flat tab
    /// already using `kind` as a no-op.
    public func changeStrategy(
        sessionID: SessionID,
        paneID: PaneID,
        kind: LayoutStrategyKind
    ) {
        connection?.send(.changeStrategy(sessionID, paneID, kind))
    }

    // MARK: - Floating Pane Operations

    public func createFloatingPane(
        sessionID: SessionID,
        tabID: TabID,
        profileID: String?,
        snapshot: StartupSnapshot?,
        variables: [String: String] = [:],
        frameHint: FloatFrameHint?
    ) {
        connection?.send(.createFloatingPane(
            sessionID, tabID,
            profileID: profileID,
            snapshot: snapshot,
            variables: variables,
            frameHint: frameHint
        ))
    }

    public func closeFloatingPane(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.closeFloatingPane(sessionID, paneID))
    }

    public func updateFloatingPaneFrame(
        sessionID: SessionID, paneID: PaneID,
        x: Float, y: Float, width: Float, height: Float
    ) {
        connection?.send(.updateFloatingPaneFrame(sessionID, paneID, x: x, y: y, width: width, height: height))
    }

    public func bringFloatingPaneToFront(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.bringFloatingPaneToFront(sessionID, paneID))
    }

    public func toggleFloatingPanePin(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.toggleFloatingPanePin(sessionID, paneID))
    }

    // MARK: - Command Execution

    /// Ask the server to run a command in-place (suspend shell, run, restore on exit).
    public func runInPlace(sessionID: SessionID, paneID: PaneID, command: String, arguments: [String]) {
        connection?.send(.runInPlace(sessionID, paneID, command: command, arguments: arguments))
    }

    /// Ask the server to run a command in the background (fire-and-forget).
    public func runRemoteCommand(sessionID: SessionID, paneID: PaneID, command: String, arguments: [String]) {
        connection?.send(.runRemoteCommand(sessionID, paneID, command: command, arguments: arguments))
    }

    /// Ask the server to restart a command in an existing (exited) floating pane.
    public func restartFloatingPaneCommand(sessionID: SessionID, paneID: PaneID, command: String, arguments: [String]) {
        connection?.send(.restartFloatingPaneCommand(sessionID, paneID, command: command, arguments: arguments))
    }

    /// Re-run the command in a zombie tree pane (Enter on an exited remote
    /// pane). The server keeps the `PaneID` stable and pushes a fresh
    /// `screenFull` afterwards to clear the pane visually.
    public func rerunPane(sessionID: SessionID, paneID: PaneID) {
        connection?.send(.rerunPane(sessionID, paneID))
    }

    // MARK: - Screen Replica Access

    /// Get the screen replica for a pane, creating one if needed.
    public func replica(for paneID: PaneID) -> ScreenReplica {
        replicaLock.lock()
        defer { replicaLock.unlock() }
        if let existing = replicas[paneID] {
            return existing
        }
        let replica = ScreenReplica()
        replicas[paneID] = replica
        return replica
    }

    /// Remove the screen replica for a pane.
    public func removeReplica(for paneID: PaneID) {
        replicaLock.lock()
        replicas.removeValue(forKey: paneID)
        replicaLock.unlock()
        cursorTraceLock.lock()
        lastCursorTrace.removeValue(forKey: paneID)
        cursorTraceLock.unlock()
    }

    /// Emit a `[RECV]` cursorTrace log iff the cursor position, pane size,
    /// or cursor visibility changed since the last log for this pane.
    /// Temporary — remove with the cursorTrace category.
    private func logCursorTraceRecv(
        paneID: PaneID,
        kind: String,
        cols: Int,
        rows: Int,
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool
    ) {
        let state = (row: cursorRow, col: cursorCol, cols: cols, rows: rows, vis: cursorVisible)
        cursorTraceLock.lock()
        if let last = lastCursorTrace[paneID], last == state {
            cursorTraceLock.unlock()
            return
        }
        lastCursorTrace[paneID] = state
        cursorTraceLock.unlock()

        guard let handler = cursorTraceHandler else { return }
        let paneShort = paneID.uuid.uuidString.prefix(8)
        handler(
            "[RECV] server=\(paneShort) kind=\(kind) dims=\(cols)x\(rows)"
            + " cursor=(\(cursorRow),\(cursorCol)) vis=\(cursorVisible)",
            paneID
        )
    }

    // MARK: - Private: Message Dispatch

    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .handshakeResult:
            // Handshake is handled synchronously before the read loop starts.
            break

        case .sessionList(let sessions):
            DispatchQueue.main.async { [weak self] in
                self?.onSessionList?(sessions)
            }

        case .sessionCreated(let info):
            DispatchQueue.main.async { [weak self] in
                self?.onSessionCreated?(info)
            }

        case .sessionClosed(let sessionID):
            DispatchQueue.main.async { [weak self] in
                self?.onSessionClosed?(sessionID)
            }

        case .screenFull(let sessionID, let paneID, let snapshot, let mouseTrackingMode):
            let rep = replica(for: paneID)
            rep.applyFullSnapshot(snapshot, mouseTrackingMode: mouseTrackingMode)
            logCursorTraceRecv(
                paneID: paneID,
                kind: "full",
                cols: snapshot.columns,
                rows: snapshot.rows,
                cursorRow: snapshot.cursorRow,
                cursorCol: snapshot.cursorCol,
                cursorVisible: snapshot.cursorVisible
            )
            DispatchQueue.main.async { [weak self] in
                self?.onScreenUpdated?(sessionID, paneID)
            }

        case .screenDiff(let sessionID, let paneID, let diff):
            let rep = replica(for: paneID)
            rep.applyDiff(diff)
            logCursorTraceRecv(
                paneID: paneID,
                kind: "diff",
                cols: Int(diff.columns),
                rows: rep.viewportInfo().rows,
                cursorRow: Int(diff.cursorRow),
                cursorCol: Int(diff.cursorCol),
                cursorVisible: diff.cursorVisible
            )
            DispatchQueue.main.async { [weak self] in
                self?.onScreenUpdated?(sessionID, paneID)
            }

        case .titleChanged(let sessionID, let paneID, let title):
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChanged?(sessionID, paneID, title)
            }

        case .cwdChanged(let sessionID, let paneID, let cwd):
            DispatchQueue.main.async { [weak self] in
                self?.onCwdChanged?(sessionID, paneID, cwd)
            }

        case .bell(let sessionID, let paneID):
            DispatchQueue.main.async { [weak self] in
                self?.onBell?(sessionID, paneID)
            }

        case .paneExited(let sessionID, let paneID, let exitCode):
            DispatchQueue.main.async { [weak self] in
                self?.onPaneExited?(sessionID, paneID, exitCode)
            }

        case .layoutUpdate(let info):
            DispatchQueue.main.async { [weak self] in
                self?.onLayoutUpdate?(info)
            }

        case .clipboardSet(let text):
            DispatchQueue.main.async { [weak self] in
                self?.onClipboardSet?(text)
            }
        }
    }
}
