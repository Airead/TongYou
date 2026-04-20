import Foundation
import TYProtocol
import TYTerminal

/// Listens on a Unix domain socket, accepts client connections,
/// and dispatches messages between clients and the session manager.
///
/// Screen updates use an event-driven model with adaptive coalescing:
/// when the screen becomes dirty, a one-shot timer is scheduled after a short
/// delay (minCoalesceDelay). During sustained output the delay ramps up
/// exponentially to maxCoalesceDelay, then resets when the screen goes idle.
public final class SocketServer: @unchecked Sendable {

    private var config: ServerConfig
    private let sessionManager: ServerSessionManager
    private var listenSocket: TYSocket?
    private var clients: [UUID: ClientConnection] = [:]
    private let clientsLock = NSLock()
    private var running = false
    private let runningLock = NSLock()
    private let authToken: String?

    /// Global set of dirty (sessionID, paneID) pairs, populated by onScreenDirty callbacks.
    /// Protected by `dirtyLock`.
    private var dirtyPanes: Set<DirtyPaneKey> = []
    /// Whether a flush is already scheduled. Protected by `dirtyLock`.
    private var flushScheduled = false
    private let dirtyLock = NSLock()

    /// Last-sent snapshot state per pane, used to suppress duplicate updates
    /// when the viewport content hasn't actually changed (e.g. scrolled up
    /// while new output arrives at the bottom).
    private var lastSentState: [PaneID: SentSnapshotState] = [:]

    /// Last cursor/geometry stamped into a `[SEND]` cursorTrace log per pane.
    /// Temporary — remove with the cursorTrace category.
    private var lastCursorTrace: [PaneID: (row: Int, col: Int, cols: Int, rows: Int, vis: Bool)] = [:]

    /// One-shot timer for the next coalesced flush. Managed on `messageQueue`.
    private var flushTimer: DispatchSourceTimer?
    /// Number of consecutive flush cycles without an idle gap.
    /// Used to compute the adaptive coalesce delay. Managed on `messageQueue`.
    private var consecutiveFlushCount = 0

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

    public init(config: ServerConfig, sessionManager: ServerSessionManager, authToken: String? = nil) {
        self.config = config
        self.sessionManager = sessionManager
        self.authToken = authToken
        wireSessionManagerCallbacks()
        DirtyTrace.log = { msg in
            // [RESIZE] / [ALT] / [MODE] / [ENV] messages belong to the
            // cursorTrace investigation; the rest are dirty-region traces.
            // Both hooks are temporary.
            if msg.hasPrefix("[RESIZE")
                || msg.hasPrefix("[ALT")
                || msg.hasPrefix("[MODE")
                || msg.hasPrefix("[ENV") {
                Log.debug(msg, category: .cursorTrace)
            } else {
                Log.debug(msg)
            }
        }
    }

    public func start() throws {
        try ServerConfig.ensureParentDirectory(for: config.socketPath)

        let socket = try TYSocket.listen(path: config.socketPath)
        listenSocket = socket

        runningLock.lock()
        running = true
        runningLock.unlock()

        startStatsTimer()
        Log.info("Server started, listening on \(config.socketPath)")
        onReady?()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        runningLock.lock()
        running = false
        let socket = listenSocket
        listenSocket = nil
        runningLock.unlock()

        socket?.closeSocket()

        flushTimer?.cancel()
        flushTimer = nil

        statsTimer?.cancel()
        statsTimer = nil

        clientsLock.lock()
        let allClients = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()

        for client in allClients {
            client.stop()
        }
        lastSentState.removeAll()
        lastCursorTrace.removeAll()
        sessionManager.stopAllSessions()
        Log.info("Server stopped")
    }

    /// Apply updated configuration at runtime.
    /// Coalesce delays and pending limits take effect immediately.
    /// Stats timer is restarted if the interval changed.
    /// Scrollback limit only applies to newly created sessions.
    public func updateConfig(_ newConfig: ServerConfig) {
        messageQueue.async { [weak self] in
            guard let self else { return }
            let oldInterval = self.config.statsInterval
            self.config = newConfig
            self.sessionManager.updateConfig(newConfig)

            // Restart stats timer if interval changed
            if oldInterval != newConfig.statsInterval {
                self.statsTimer?.cancel()
                self.statsTimer = nil
                self.startStatsTimer()
            }
        }
    }

    public var clientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    // MARK: - Broadcast Helpers

    /// Emit a `[SEND]` cursorTrace log iff the cursor position, pane size,
    /// or cursor visibility changed since the last log for this pane.
    /// Temporary — remove with the cursorTrace category.
    private func logCursorTraceSend(paneID: PaneID, paneShort: Substring, snapshot: ScreenSnapshot) {
        let state = (
            row: snapshot.cursorRow,
            col: snapshot.cursorCol,
            cols: snapshot.columns,
            rows: snapshot.rows,
            vis: snapshot.cursorVisible
        )
        if let last = lastCursorTrace[paneID], last == state { return }
        lastCursorTrace[paneID] = state

        let cellsAround = sampleCursorRowCells(snapshot: snapshot)
        Log.debug(
            "[SEND] pane=\(paneShort) dims=\(state.cols)x\(state.rows)"
            + " cursor=(\(state.row),\(state.col)) vis=\(state.vis)"
            + " cellsAround=\(cellsAround)",
            category: .cursorTrace
        )
    }

    /// Sample up to ±5 cells around the cursor column on the cursor row.
    /// For partial snapshots, falls back to `[partial]` when the cursor row
    /// isn't in `partialRows` (i.e. didn't change this flush).
    private func sampleCursorRowCells(snapshot: ScreenSnapshot) -> String {
        let row = snapshot.cursorRow
        let col = snapshot.cursorCol
        guard row >= 0, row < snapshot.rows, snapshot.columns > 0 else { return "[]" }
        let startCol = max(0, col - 5)
        let endCol = min(snapshot.columns - 1, col + 5)
        guard startCol <= endCol else { return "[]" }

        let rowCells: [Cell]
        if !snapshot.isPartial {
            let rowBase = row * snapshot.columns
            guard rowBase + endCol < snapshot.cells.count else { return "[?]" }
            rowCells = Array(snapshot.cells[rowBase..<(rowBase + snapshot.columns)])
        } else if let pair = snapshot.partialRows.first(where: { $0.row == row }) {
            rowCells = pair.cells
        } else {
            return "[partial]"
        }
        guard endCol < rowCells.count else { return "[?]" }

        var parts: [String] = []
        parts.reserveCapacity(endCol - startCol + 1)
        for c in startCol...endCol {
            let cell = rowCells[c]
            let prefix = c == col ? "▮" : ""
            let scalar = cell.content.firstScalar
            let ch: String
            if let s = scalar, s.value >= 0x20, s.value != 0x7F {
                ch = String(s)
            } else {
                ch = "·"
            }
            parts.append(prefix + ch)
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

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
        while true {
            runningLock.lock()
            let isRunning = running
            let socket = listenSocket
            runningLock.unlock()
            guard isRunning, let socket else { return }

            do {
                let clientSocket = try socket.accept()

                // Verify the connecting process belongs to the same user.
                do {
                    let (peerUID, _) = try clientSocket.peerCredentials()
                    if peerUID != getuid() {
                        Log.warning("Rejected connection from UID \(peerUID) (expected \(getuid()))")
                        clientSocket.closeSocket()
                        continue
                    }
                } catch {
                    Log.warning("Failed to get peer credentials, rejecting: \(error)")
                    clientSocket.closeSocket()
                    continue
                }

                let connection = ClientConnection(
                    socket: clientSocket,
                    maxPendingScreenUpdates: config.maxPendingScreenUpdates,
                    expectedToken: authToken
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
            } catch TYSocketError.acceptFailed(let e) where e == EBADF {
                return
            } catch {
                runningLock.lock()
                let stillRunning = running
                runningLock.unlock()
                if !stillRunning { return }
                Log.error("Accept loop error: \(error)")
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

    // MARK: - Private: Adaptive Coalescing

    /// Compute the coalesce delay based on how many consecutive flushes occurred.
    /// Exponential ramp: minDelay * 2^count, capped at maxDelay.
    private func coalesceDelay(for consecutiveCount: Int) -> TimeInterval {
        let base = config.minCoalesceDelay * pow(2.0, Double(consecutiveCount))
        return min(base, config.maxCoalesceDelay)
    }

    /// Called from any queue via `onScreenDirty`. If no flush is pending,
    /// dispatches to `messageQueue` to schedule one.
    private func scheduleFlushIfNeeded() {
        dirtyLock.lock()
        guard !flushScheduled else {
            dirtyLock.unlock()
            return
        }
        flushScheduled = true
        dirtyLock.unlock()

        messageQueue.async { [weak self] in
            self?.scheduleFlush()
        }
    }

    /// Schedule a one-shot timer for the next flush. Must run on `messageQueue`.
    private func scheduleFlush() {
        let delay = coalesceDelay(for: consecutiveFlushCount)
        let timer = DispatchSource.makeTimerSource(queue: messageQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.performFlush()
        }
        timer.resume()
        flushTimer?.cancel()
        flushTimer = timer
    }

    private func startStatsTimer() {
        guard config.statsInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: messageQueue)
        timer.schedule(deadline: .now() + config.statsInterval, repeating: config.statsInterval)
        timer.setEventHandler { [weak self] in
            self?.logStats()
        }
        timer.resume()
        statsTimer = timer
    }

    /// Consume each dirty pane's snapshot once and send to all attached clients.
    /// After flushing, if more dirty panes arrived during the send, schedule
    /// another flush with an increased coalesce delay. Otherwise reset to idle.
    private func performFlush() {
        dirtyLock.lock()
        let panes = dirtyPanes
        dirtyPanes.removeAll(keepingCapacity: true)
        dirtyLock.unlock()

        guard !panes.isEmpty else {
            dirtyLock.lock()
            flushScheduled = false
            dirtyLock.unlock()
            consecutiveFlushCount = 0
            return
        }

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
            let dirtyCount = snapshot.isPartial ? snapshot.dirtyRows.count : snapshot.dirtyRegion.dirtyCount
            let mostlyDirty = !hasScrollDelta && dirtyCount >= snapshot.rows * 4 / 5
            if mostlyDirty && snapshot.isPartial {
                let sampleCount = min(5, snapshot.partialRows.count)
                let sample = snapshot.partialRows.prefix(sampleCount).map { row, cells -> String in
                    let firstNonBlank = cells.first { $0.codepoint != " " && $0.width.isRenderable }
                    let cp = firstNonBlank.map { String($0.codepoint) } ?? "·"
                    return "r\(row):\(cp)"
                }.joined(separator: " ")
                Log.debug(
                    "High-dirty partial for pane \(paneShort) rows=\(dirtyCount)/\(snapshot.rows)"
                    + " fullRebuild=\(snapshot.dirtyRegion.fullRebuild)"
                    + " scrollDelta=\(snapshot.dirtyRegion.scrollDelta)"
                    + " sample=[\(sample)]"
                )
            }
            if !snapshot.isPartial && (snapshot.dirtyRegion.fullRebuild || mostlyDirty) {
                message = .screenFull(key.sessionID, key.paneID, snapshot, mouseTrackingMode: mouseMode)
            } else {
                let diff = ScreenDiff(from: snapshot, mouseTrackingMode: mouseMode)
                message = .screenDiff(key.sessionID, key.paneID, diff)
            }

            logCursorTraceSend(paneID: key.paneID, paneShort: paneShort, snapshot: snapshot)

            forEachAttachedClient(session: key.sessionID) { $0.send(message) }
        }

        // Check if more dirty panes arrived during the flush.
        dirtyLock.lock()
        let hasPending = !dirtyPanes.isEmpty
        if !hasPending {
            flushScheduled = false
        }
        dirtyLock.unlock()

        if hasPending {
            consecutiveFlushCount += 1
            scheduleFlush()
        } else {
            flushTimer = nil
            consecutiveFlushCount = 0
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
        case .handshake:
            // Handled by ClientConnection's readLoop before reaching here.
            break

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

        case .paste(_, let paneID, let bytes):
            sessionManager.sendPaste(paneID: paneID, data: bytes)

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

        case .createTab(let sessionID, let profileID, let snapshot, let variables):
            if sessionManager.createTab(
                sessionID: sessionID,
                profileID: profileID,
                snapshot: snapshot,
                variables: variables
            ) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .closeTab(let sessionID, let tabID):
            sessionManager.closeTab(sessionID: sessionID, tabID: tabID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .splitPane(let sessionID, let paneID, let direction, let profileID, let snapshot, let variables):
            if sessionManager.splitPane(
                sessionID: sessionID, paneID: paneID, direction: direction,
                profileID: profileID,
                snapshot: snapshot,
                variables: variables
            ) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .closePane(let sessionID, let paneID):
            sessionManager.closePane(sessionID: sessionID, paneID: paneID)
            broadcastLayoutOrClosed(sessionID: sessionID)

        case .focusPane(let sessionID, let paneID):
            sessionManager.focusPane(sessionID: sessionID, paneID: paneID)

        case .paneFocusEvent(_, let paneID, let focused):
            sessionManager.reportPaneFocus(paneID: paneID, focused: focused)

        case .selectTab(let sessionID, let tabIndex):
            sessionManager.selectTab(sessionID: sessionID, tabIndex: Int(tabIndex))

        case .setSplitRatio(let sessionID, let paneID, let ratio):
            if sessionManager.setSplitRatio(
                sessionID: sessionID, paneID: paneID, ratio: ratio
            ) {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .createFloatingPane(let sessionID, let tabID, let profileID, let snapshot, let variables, let frameHint):
            if sessionManager.createFloatingPane(
                sessionID: sessionID, tabID: tabID,
                profileID: profileID,
                snapshot: snapshot,
                variables: variables,
                frameHint: frameHint
            ) != nil {
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

        case .runInPlace(let sessionID, let paneID, let command, let arguments):
            sessionManager.runInPlace(
                sessionID: sessionID, paneID: paneID,
                command: command, arguments: arguments
            )

        case .runRemoteCommand(_, let paneID, let command, let arguments):
            sessionManager.runRemoteCommand(
                paneID: paneID, command: command, arguments: arguments
            )

        case .restartFloatingPaneCommand(let sessionID, let paneID, let command, let arguments):
            if sessionManager.restartFloatingPaneCommand(
                sessionID: sessionID, paneID: paneID,
                command: command, arguments: arguments
            ) {
                sendFullSnapshot(to: client, sessionID: sessionID, paneID: paneID)
            }

        case .rerunPane(let sessionID, let paneID):
            // Mirrors local `rerunTreePaneCommand`: stop the old core,
            // start a fresh one with the same snapshot, keep the PaneID.
            // Send an immediate fresh snapshot so the client's zombie-pane
            // contents are replaced without waiting for the first draw.
            sessionManager.rerunPane(sessionID: sessionID, paneID: paneID)
            sendFullSnapshot(to: client, sessionID: sessionID, paneID: paneID)

        case .movePane(let sessionID, let sourcePaneID, let targetPaneID, let side):
            if sessionManager.movePane(
                sessionID: sessionID,
                sourcePaneID: sourcePaneID,
                targetPaneID: targetPaneID,
                side: side
            ) {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .changeStrategy(let sessionID, let paneID, let kind):
            if sessionManager.changeStrategy(
                sessionID: sessionID,
                paneID: paneID,
                kind: kind
            ) {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .createTabWithGridPanes(let sessionID, let specs):
            if sessionManager.createTabWithGridPanes(
                sessionID: sessionID,
                specs: specs
            ) != nil {
                broadcastLayoutOrClosed(sessionID: sessionID)
            }

        case .refreshPane(let sessionID, let paneID):
            // Diagnostic — just force-push the current Screen state back to
            // this client (no PTY side-effect). Used to triage the split-pane
            // misalignment bug against the real Ctrl+L (which triggers an
            // app-level redraw in the foreground program).
            Log.debug(
                "[REFRESH] pane=\(String(paneID.uuid.uuidString.prefix(8)))"
                + " session=\(sessionID)",
                category: .cursorTrace
            )
            sendFullSnapshot(to: client, sessionID: sessionID, paneID: paneID)
        }
    }

    private func sendFullSnapshot(to client: ClientConnection, sessionID: SessionID, paneID: PaneID) {
        if let snapshot = sessionManager.snapshot(paneID: paneID) {
            let mouseMode = sessionManager.mouseTrackingMode(paneID: paneID)
            client.send(.screenFull(sessionID, paneID, snapshot, mouseTrackingMode: mouseMode))
        }
    }

    private func sendFullSnapshots(to client: ClientConnection, sessionID: SessionID) {
        for paneID in sessionManager.allPaneIDs(sessionID: sessionID) {
            sendFullSnapshot(to: client, sessionID: sessionID, paneID: paneID)
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
            self.scheduleFlushIfNeeded()
        }

        sessionManager.onTitleChanged = { [weak self] sessionID, paneID, title in
            self?.broadcast(.titleChanged(sessionID, paneID, title), toSession: sessionID)
        }

        sessionManager.onCwdChanged = { [weak self] sessionID, paneID, cwd in
            self?.broadcast(.cwdChanged(sessionID, paneID, cwd), toSession: sessionID)
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
                self?.lastCursorTrace.removeValue(forKey: paneID)
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
