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

    /// Single server-wide timer for coalescing screen updates.
    private var updateTimer: DispatchSourceTimer?

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
        onReady?()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        updateTimer?.cancel()
        updateTimer = nil

        listenSocket?.closeSocket()
        listenSocket = nil

        clientsLock.lock()
        let allClients = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()

        for client in allClients {
            client.stop()
        }
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

    /// Broadcast a layout update for the active tab of a session.
    /// If the session no longer exists, broadcasts sessionClosed and checks auto-exit.
    private func broadcastLayoutOrClosed(sessionID: SessionID) {
        if let info = sessionManager.sessionInfo(for: sessionID),
           info.activeTabIndex < info.tabs.count {
            let layout = info.tabs[info.activeTabIndex].layout
            broadcast(.layoutUpdate(sessionID, layout), toSession: sessionID)
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
                let connection = ClientConnection(socket: clientSocket)

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

                connection.startReadLoop()
            } catch {
                if self.listenSocket == nil { return }
                continue
            }
        }
    }

    private func removeClient(_ client: ClientConnection) {
        clientsLock.lock()
        clients.removeValue(forKey: client.id)
        clientsLock.unlock()
        client.stop()
    }

    // MARK: - Private: Screen Update Timer

    private func startUpdateTimer() {
        let timer = DispatchSource.makeTimerSource(queue: messageQueue)
        timer.schedule(
            deadline: .now() + config.screenUpdateInterval,
            repeating: config.screenUpdateInterval
        )
        timer.setEventHandler { [weak self] in
            self?.flushDirtyPanes()
        }
        timer.resume()
        updateTimer = timer
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

            let message: ServerMessage
            if snapshot.dirtyRegion.fullRebuild {
                message = .screenFull(key.sessionID, key.paneID, snapshot)
            } else {
                message = .screenDiff(key.sessionID, key.paneID, ScreenDiff(from: snapshot))
            }

            forEachAttachedClient(session: key.sessionID) { $0.send(message) }
        }
    }

    // MARK: - Private: Message Dispatch

    private func handleClientMessage(_ message: ClientMessage, from client: ClientConnection) {
        switch message {
        case .listSessions:
            client.send(.sessionList(sessionManager.listSessions()))

        case .createSession(let name):
            let info = sessionManager.createSession(name: name)
            client.attach(sessionID: info.id)
            broadcastAll(.sessionCreated(info))

        case .attachSession(let sessionID):
            client.attach(sessionID: sessionID)
            sendFullSnapshots(to: client, sessionID: sessionID)

        case .detachSession(let sessionID):
            client.detach(sessionID: sessionID)

        case .closeSession(let sessionID):
            sessionManager.closeSession(id: sessionID)
            broadcastAll(.sessionClosed(sessionID))
            checkAutoExit()

        case .input(_, let paneID, let bytes):
            sessionManager.sendInput(paneID: paneID, data: bytes)

        case .resize(_, let paneID, let cols, let rows):
            sessionManager.resizePane(paneID: paneID, cols: cols, rows: rows)

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

        case .focusPane(_, _):
            break
        }
    }

    private func sendFullSnapshots(to client: ClientConnection, sessionID: SessionID) {
        for paneID in sessionManager.allPaneIDs(sessionID: sessionID) {
            if let snapshot = sessionManager.snapshot(paneID: paneID) {
                client.send(.screenFull(sessionID, paneID, snapshot))
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
            self?.broadcast(
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
