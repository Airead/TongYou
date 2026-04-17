import Foundation
import TYProtocol
import TYTerminal

/// Listens on a Unix domain socket, accepts client connections,
/// and dispatches messages between clients and the session manager.
///
/// Screen updates use a single server-wide timer that consumes each dirty pane's
/// snapshot once and distributes it to all attached clients, avoiding races
/// where multiple clients compete to consume the same snapshot.
public final class SocketServer: @unchecked Sendable {

    private let config: ServerConfig
    private let sessionManager: ServerSessionManager
    private var listenSocket: TYSocket?
    private var clients: [UUID: ClientConnection] = [:]
    private let clientsLock = NSLock()

    /// Global set of dirty (sessionID, paneID) pairs, populated by onScreenDirty callbacks.
    private var dirtyPanes: Set<DirtyPaneKey> = []
    private let dirtyLock = NSLock()

    /// Last-sent snapshot state per pane, used to suppress duplicate updates
    /// when the viewport content hasn't actually changed (e.g. scrolled up
    /// while new output arrives at the bottom).
    private var lastSentState: [PaneID: SentSnapshotState] = [:]

    /// Single server-wide timer for coalescing screen updates.
    private var updateTimer: DispatchSourceTimer?

    /// Periodic stats logging timer.
    private var statsTimer: DispatchSourceTimer?

    private let acceptQueue = DispatchQueue(
        label: "io.github.airead.tongyou.server.accept",
        qos: .userInitiated
    )
    /// Serial queue for all sessionManager mutations and message handling.
    /// Prevents data races when multiple client readQueues dispatch concurrently.
    private let messageQueue = DispatchQueue(
        label: "io.github.airead.tongyou.server.message",
        qos: .userInteractive
    )

    public var onReady: (() -> Void)?
    public var onAllSessionsClosed: (() -> Void)?

    public init(config: ServerConfig, sessionManager: ServerSessionManager) {
        self.config = config
        self.sessionManager = sessionManager
        wireSessionManagerCallbacks()
    }

    // MARK: - Server Lifecycle

    public func start() throws {
        try ServerConfig.ensureParentDirectory(for: config.socketPath)

        let socket = try TYSocket.listen(path: config.socketPath)
        listenSocket = socket

        startUpdateTimer()
        startStatsTimer()
        Log.info("Server started, listening on \(config.socketPath)")
        onReady?()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        updateTimer?.cancel()
        updateTimer = nil

        statsTimer?.cancel()
        statsTimer = nil

        listenSocket?.closeSocket()
        listenSocket = nil

        clientsLock.lock()
        let allClients = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()

        for client in allClients {
            client.stop()
        }
        lastSentState.removeAll()
        Log.info("Server stopped")
    }

    public var clientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    // MARK: - Broadcast Helpers

    /// Run an action on each client attached to a session.
    private func forEachAttachedClient(
        session sessionID: SessionID,
        _ action: (ClientConnection) -> Void
    ) {
        clientsLock.lock()
        let attached = clients.values.filter { $0.isAttached(to: sessionID) }
        clientsLock.unlock()
        for client in attached { action(client) }
    }

    private func broadcast(_ message: ServerMessage, toSession sessionID: SessionID) {
        forEachAttachedClient(session: sessionID) { $0.send(message) }
    }

    private func broadcastAll(_ message: ServerMessage) {
        clientsLock.lock()
        let allClients = Array(clients.values)
        clientsLock.unlock()
        for client in allClients { client.send(message) }
    }

    /// Broadcast a full session layout update to all attached clients.
    /// If the session no longer exists, broadcasts sessionClosed and checks auto-exit.
    private func broadcastLayoutOrClosed(sessionID: SessionID) {
        if let info = sessionManager.sessionInfo(for: sessionID) {
            broadcast(.layoutUpdate(info), toSession: sessionID)
        } else {
            broadcastAll(.sessionClosed(sessionID))
            checkAutoExit()
        }
    }

    // MARK: - Private: Accept Loop

    private func acceptLoop() {
        while let listenSocket {
            do {
                let clientSocket = try listenSocket.accept()
                let connection = ClientConnection(
                    socket: clientSocket,
                    maxPendingScreenUpdates: config.maxPendingScreenUpdates
                )

                connection.onMessage = { [weak self, weak connection] message in
                    guard let self, let connection else { return }
                    self.messageQueue.async {
                        self.handleClientMessage(message, from: connection)
                    }
                }

                connection.onDisconnect = { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.removeClient(connection)
                }

                clientsLock.lock()
                clients[connection.id] = connection
                clientsLock.unlock()

                Log.info("Client accepted: \(connection.id.uuidString.prefix(8)), total: \(clientCount)")

                connection.startReadLoop()
            } catch {
                if self.listenSocket == nil { return }
                Log.error("Accept loop error: \(error)")
                continue
            }
        }
    }

    private func removeClient(_ client: ClientConnection) {
        clientsLock.lock()
        clients.removeValue(forKey: client.id)
        clientsLock.unlock()
        client.stop()
        Log.info("Client removed: \(client.id.uuidString.prefix(8)), remaining: \(clientCount)")

        // Clean up client size entries on messageQueue (sessionManager is not thread-safe)
        let clientID = client.id
        Log.debug("Scheduling size cleanup for disconnected client \(clientID.uuidString.prefix(8))")
        messageQueue.async { [weak self] in
            self?.sessionManager.removeClientFromAllPanes(clientID: clientID)
        }
    }

    // MARK: - Private: Timers

    private func makeTimer(interval: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: messageQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func startUpdateTimer() {
        updateTimer = makeTimer(interval: config.screenUpdateInterval) { [weak self] in
            self?.flushDirtyPanes()
        }
    }

    private func startStatsTimer() {
        guard config.statsInterval > 0 else { return }
        statsTimer = makeTimer(interval: config.statsInterval) { [weak self] in
            self?.logStats()
        }
    }

    /// Consume each dirty pane's snapshot once and send to all attached clients.
    private func flushDirtyPanes() {
        dirtyLock.lock()
        let panes = dirtyPanes
        dirtyPanes.removeAll(keepingCapacity: true)
        dirtyLock.unlock()

        guard !panes.isEmpty else { return }

        for key in panes {
            guard let snapshot = sessionManager.consumeSnapshot(
                paneID: key.paneID
            ) else { continue }

            // Suppress duplicate updates: if viewport content hasn't changed
            // (e.g. user scrolled up while new output arrives at the bottom),
            // skip sending entirely.
            let paneShort = key.paneID.uuid.uuidString.prefix(8)
            if let prev = lastSentState[key.paneID] {
                if prev.matches(snapshot) {
                    Log.debug(
                        "Suppressed duplicate for pane \(paneShort)"
                        + " (vpOff=\(snapshot.viewportOffset), sb=\(snapshot.scrollbackCount), prevSb=\(prev.scrollbackCount))"
                    )
                    continue
                } else {
                    Log.debug(
                        "Dedup miss for pane \(paneShort)"
                        + " (vpOff=\(prev.viewportOffset)->\(snapshot.viewportOffset)"
                        + ", sb=\(prev.scrollbackCount)->\(snapshot.scrollbackCount)"
                        + ", cursor=\(prev.cursorCol),\(prev.cursorRow)->\(snapshot.cursorCol),\(snapshot.cursorRow)"
                        + ", vis=\(prev.cursorVisible)->\(snapshot.cursorVisible))"
                    )
                }
            } else {
                Log.debug("No prev state for pane \(paneShort), first send")
            }
            lastSentState[key.paneID] = SentSnapshotState(from: snapshot)

            let mouseMode = sessionManager.mouseTrackingMode(paneID: key.paneID)

            let message: ServerMessage
            // Use full snapshot when the screen was fully rebuilt OR when
            // ≥80% of rows are dirty (without scroll optimization) — at that
            // point a diff carries more overhead than a plain full snapshot.
            // When scrollDelta is set, the dirty rows are only the newly
            // revealed ones, so skip the mostlyDirty heuristic.
            let hasScrollDelta = snapshot.dirtyRegion.scrollDelta > 0
            let dirtyCount = snapshot.isPartial ? snapshot.dirtyRows.count : snapshot.dirtyRegion.dirtyRows.count
            let mostlyDirty = !hasScrollDelta && dirtyCount >= snapshot.rows * 4 / 5
            if snapshot.dirtyRegion.fullRebuild || mostlyDirty {
                message = .screenFull(key.sessionID, key.paneID, snapshot, mouseTrackingMode: mouseMode)
            } else {
                var diff = ScreenDiff(from: snapshot)
                diff = ScreenDiff(
                    dirtyRows: diff.dirtyRows, cellData: diff.cellData,
                    columns: diff.columns,
                    cursorCol: diff.cursorCol, cursorRow: diff.cursorRow,
                    cursorVisible: diff.cursorVisible, cursorShape: diff.cursorShape,
                    scrollbackCount: diff.scrollbackCount, viewportOffset: diff.viewportOffset,
                    mouseTrackingMode: mouseMode,
                    scrollDelta: diff.scrollDelta
                )
                message = .screenDiff(key.sessionID, key.paneID, diff)
            }

            forEachAttachedClient(session: key.sessionID) { $0.send(message) }
        }
    }

    private func logStats() {
        clientsLock.lock()
        let allClients = Array(clients.values)
        let count = allClients.count
        clientsLock.unlock()

        let sessions = sessionManager.sessionCount
        let pendingInfo = allClients.map { client in
            "\(client.id.uuidString.prefix(8)):\(client.pendingScreenUpdateCount)"
        }.joined(separator: ", ")

        let rss = Self.residentMemoryBytes()
        let rssMB = String(format: "%.1f", Double(rss) / 1_048_576.0)

        Log.info(
            "Stats: clients=\(count), sessions=\(sessions), rss=\(rssMB)MB, pending=[\(pendingInfo)]"
        )
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: - Private: Message Dispatch

    private func handleClientMessage(_ message: ClientMessage, from client: ClientConnection) {
        Log.debug("RECV [\(client.id.uuidString.prefix(8))] \(message.debugDescription)")
        switch message {
        case .listSessions:
            client.send(.sessionList(sessionManager.listSessions()))

        case .createSession(let name):
            let info = sessionManager.createSession(name: name)
            client.attach(sessionID: info.id)
            broadcastAll(.sessionCreated(info))

        case .attachSession(let sessionID):
            client.attach(sessionID: sessionID)
            // Send layout so the client can rebuild tabs/panes before screen data.
            if let info = sessionManager.sessionInfo(for: sessionID) {
                client.send(.layoutUpdate(info))
            }
            sendFullSnapshots(to: client, sessionID: sessionID)

        case .detachSession(let sessionID):
            client.detach(sessionID: sessionID)
            for paneID in sessionManager.allPaneIDs(sessionID: sessionID) {
                sessionManager.removeClientFromPane(clientID: client.id, paneID: paneID)
            }

        case .closeSession(let sessionID):
            sessionManager.closeSession(id: sessionID)
            broadcastAll(.sessionClosed(sessionID))
            checkAutoExit()

        case .renameSession(let sessionID, let name):
            sessionManager.renameSession(id: sessionID, name: name)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .input(_, let paneID, let bytes):
            sessionManager.sendInput(paneID: paneID, data: bytes)

        case .mouseEvent(_, let paneID, let event):
            sessionManager.handleMouseEvent(paneID: paneID, event: event)

        case .resize(_, let paneID, let cols, let rows):
            sessionManager.registerClientSize(
                clientID: client.id, paneID: paneID, cols: cols, rows: rows
            )

        case .scrollViewport(_, let paneID, let delta):
            sessionManager.scrollViewport(paneID: paneID, delta: delta)

        case .extractSelection(_, let paneID, let selection):
            if let text = sessionManager.extractText(paneID: paneID, selection: selection),
               !text.isEmpty {
                client.send(.clipboardSet(text))
            }

        case .createTab(let sessionID):
            if sessionManager.createTab(sessionID: sessionID) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .closeTab(let sessionID, let tabID):
            sessionManager.closeTab(sessionID: sessionID, tabID: tabID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .splitPane(let sessionID, let paneID, let direction):
            if sessionManager.splitPane(
                sessionID: sessionID, paneID: paneID, direction: direction
            ) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .closePane(let sessionID, let paneID):
            sessionManager.closePane(sessionID: sessionID, paneID: paneID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .focusPane(let sessionID, let paneID):
            sessionManager.focusPane(sessionID: sessionID, paneID: paneID)

        case .selectTab(let sessionID, let tabIndex):
            sessionManager.selectTab(sessionID: sessionID, tabIndex: Int(tabIndex))

        case .createFloatingPane(let sessionID, let tabID):
            if sessionManager.createFloatingPane(sessionID: sessionID, tabID: tabID) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .closeFloatingPane(let sessionID, let paneID):
            sessionManager.closeFloatingPane(sessionID: sessionID, paneID: paneID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .updateFloatingPaneFrame(let sessionID, let paneID, let x, let y, let width, let height):
            // Store the frame on the server but don't broadcast — the sending client
            // already has the correct frame locally, and other clients will receive
            // the updated position on the next structural layout change.
            // Broadcasting here would serialize the full SessionInfo on every drag pixel.
            sessionManager.updateFloatingPaneFrame(
                sessionID: sessionID, paneID: paneID,
                x: x, y: y, width: width, height: height
            )

        case .bringFloatingPaneToFront(let sessionID, let paneID):
            sessionManager.bringFloatingPaneToFront(sessionID: sessionID, paneID: paneID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .toggleFloatingPanePin(let sessionID, let paneID):
            sessionManager.toggleFloatingPanePin(sessionID: sessionID, paneID: paneID)
            broadcastLayoutOrClosed(sessionID: sessionID)
        }
    }

    private func sendFullSnapshots(to client: ClientConnection, sessionID: SessionID) {
        for paneID in sessionManager.allPaneIDs(sessionID: sessionID) {
            if let snapshot = sessionManager.snapshot(paneID: paneID) {
                let mouseMode = sessionManager.mouseTrackingMode(paneID: paneID)
                client.send(.screenFull(sessionID, paneID, snapshot, mouseTrackingMode: mouseMode))
            }
        }
    }

    private func checkAutoExit() {
        if config.autoExitOnNoSessions && !sessionManager.hasSessions {
            onAllSessionsClosed?()
        }
    }

    // MARK: - Private: Session Manager Callbacks

    private func wireSessionManagerCallbacks() {
        sessionManager.onScreenDirty = { [weak self] sessionID, paneID in
            guard let self else { return }
            self.dirtyLock.lock()
            self.dirtyPanes.insert(DirtyPaneKey(sessionID: sessionID, paneID: paneID))
            self.dirtyLock.unlock()
        }

        sessionManager.onTitleChanged = { [weak self] sessionID, paneID, title in
            self?.broadcast(.titleChanged(sessionID, paneID, title), toSession: sessionID)
        }

        sessionManager.onBell = { [weak self] sessionID, paneID in
            self?.broadcast(.bell(sessionID, paneID), toSession: sessionID)
        }

        sessionManager.onClipboardSet = { [weak self] text in
            self?.broadcastAll(.clipboardSet(text))
        }

        sessionManager.onPaneExited = { [weak self] sessionID, paneID, exitCode in
            guard let self else { return }
            self.messageQueue.async { [weak self] in
                self?.lastSentState.removeValue(forKey: paneID)
            }
            self.broadcast(
                .paneExited(sessionID, paneID, exitCode: exitCode),
                toSession: sessionID
            )
        }
    }
}

private struct DirtyPaneKey: Hashable {
    let sessionID: SessionID
    let paneID: PaneID
}

/// Lightweight record of the last snapshot sent for a pane,
/// used to detect and suppress duplicate screen updates.
private struct SentSnapshotState {
    let cells: [Cell]
    let cursorCol: Int
    let cursorRow: Int
    let cursorVisible: Bool
    let cursorShape: CursorShape
    let viewportOffset: Int
    let scrollbackCount: Int

    init(from snapshot: ScreenSnapshot) {
        self.cells = snapshot.isPartial ? [] : snapshot.cells
        self.cursorCol = snapshot.cursorCol
        self.cursorRow = snapshot.cursorRow
        self.cursorVisible = snapshot.cursorVisible
        self.cursorShape = snapshot.cursorShape
        self.viewportOffset = snapshot.viewportOffset
        self.scrollbackCount = snapshot.scrollbackCount
    }

    /// Check whether the snapshot represents the same visible content.
    /// Falls back to full cell comparison when the fast path doesn't apply.
    func matches(_ snapshot: ScreenSnapshot) -> Bool {
        // Cannot deduplicate when either side is partial.
        guard !snapshot.isPartial, !cells.isEmpty else { return false }

        // Scrolled-up fast path: both viewports are scrolled up and anchored
        // to the same absolute line (scrollbackCount - viewportOffset).
        // New output only appends to scrollback below the viewport, so the
        // visible rows are identical — skip without comparing cells.
        if viewportOffset > 0 && snapshot.viewportOffset > 0
            && (scrollbackCount - viewportOffset) == (snapshot.scrollbackCount - snapshot.viewportOffset)
            && snapshot.scrollbackCount >= scrollbackCount {
            return true
        }

        // At bottom or viewport moved: compare cursor and cell content.
        guard viewportOffset == snapshot.viewportOffset,
              cursorCol == snapshot.cursorCol,
              cursorRow == snapshot.cursorRow,
              cursorVisible == snapshot.cursorVisible,
              cursorShape == snapshot.cursorShape else {
            return false
        }

        return cells == snapshot.cells
    }
}
