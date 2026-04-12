import Testing
import Foundation
@testable import TYClient
import TYProtocol
import TYServer
import TYTerminal

@Suite("TYClient Tests", .serialized)
struct TYClientTests {

    // MARK: - ScreenReplica Tests

    @Test("ScreenReplica applies full snapshot")
    func screenReplicaFullSnapshot() {
        let replica = ScreenReplica(columns: 4, rows: 2)

        let cells = (0..<8).map { i in
            Cell(codepoint: Unicode.Scalar(UInt32(0x41 + i))!, attributes: .default, width: .normal)
        }
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: 4,
            rows: 2,
            cursorCol: 2,
            cursorRow: 1,
            cursorVisible: true,
            cursorShape: .bar,
            selection: nil,
            scrollbackCount: 0,
            viewportOffset: 0,
            dirtyRegion: .full
        )

        replica.applyFullSnapshot(snapshot)

        let result = replica.consumeSnapshot()
        #expect(result != nil)
        #expect(result?.columns == 4)
        #expect(result?.rows == 2)
        #expect(result?.cursorCol == 2)
        #expect(result?.cursorRow == 1)
        #expect(result?.cursorShape == .bar)
        #expect(result?.cells.count == 8)
        #expect(result?.cell(at: 0, row: 0).codepoint == Unicode.Scalar("A"))
    }

    @Test("ScreenReplica applies incremental diff")
    func screenReplicaDiff() {
        let replica = ScreenReplica(columns: 4, rows: 3)

        // First, apply a full snapshot.
        let initialCells = [Cell](repeating: .empty, count: 12)
        let snapshot = ScreenSnapshot(
            cells: initialCells,
            columns: 4,
            rows: 3,
            cursorCol: 0,
            cursorRow: 0,
            cursorVisible: true,
            cursorShape: .block,
            selection: nil,
            scrollbackCount: 0,
            viewportOffset: 0,
            dirtyRegion: .full
        )
        replica.applyFullSnapshot(snapshot)
        _ = replica.consumeSnapshot() // Clear dirty flag.

        // Apply a diff that changes row 1.
        let newCells = (0..<4).map { i in
            Cell(codepoint: Unicode.Scalar(UInt32(0x58 + i))!, attributes: .default, width: .normal)
        }
        let diff = ScreenDiff(
            dirtyRows: [1],
            cellData: newCells,
            columns: 4,
            cursorCol: 3,
            cursorRow: 1,
            cursorVisible: true,
            cursorShape: .underline
        )

        replica.applyDiff(diff)

        let result = replica.consumeSnapshot()
        #expect(result != nil)
        #expect(result?.cursorCol == 3)
        #expect(result?.cursorRow == 1)
        #expect(result?.cursorShape == .underline)
        // Row 1 should have the new cells.
        #expect(result?.cell(at: 0, row: 1).codepoint == Unicode.Scalar("X"))
        // Row 0 should still be empty.
        #expect(result?.cell(at: 0, row: 0).codepoint == Unicode.Scalar(" "))
    }

    @Test("ScreenReplica returns nil when not dirty")
    func screenReplicaNotDirty() {
        let replica = ScreenReplica(columns: 4, rows: 2)
        // No updates applied — should not be dirty.
        let result = replica.consumeSnapshot()
        #expect(result == nil)
    }

    @Test("ScreenReplica markDirty forces next consumeSnapshot to return")
    func screenReplicaMarkDirty() {
        let replica = ScreenReplica(columns: 4, rows: 2)

        // Apply snapshot, consume it.
        let cells = [Cell](repeating: .empty, count: 8)
        let snapshot = ScreenSnapshot(
            cells: cells, columns: 4, rows: 2,
            cursorCol: 0, cursorRow: 0, cursorVisible: true, cursorShape: .block,
            selection: nil, scrollbackCount: 0, viewportOffset: 0, dirtyRegion: .full
        )
        replica.applyFullSnapshot(snapshot)
        _ = replica.consumeSnapshot()
        #expect(replica.consumeSnapshot() == nil)

        // Mark dirty manually.
        replica.markDirty()
        #expect(replica.consumeSnapshot() != nil)
    }

    // MARK: - TYDConnection Tests

    @Test("TYDConnection send/receive round-trip through server")
    func connectionRoundTrip() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-test-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.2)

        // Connect using TYDConnection.
        let socket = try TYSocket.connect(path: socketPath)
        let conn = TYDConnection(socket: socket)

        // Give the server time to accept and register the client.
        Thread.sleep(forTimeInterval: 0.1)

        // Synchronous request: list sessions (should be empty).
        try conn.sendSync(ClientMessage.listSessions)
        let response = try conn.receiveSync()

        if case .sessionList(let sessions) = response {
            #expect(sessions.isEmpty)
        } else {
            Issue.record("Expected sessionList, got \(response)")
        }

        // Create a session.
        try conn.sendSync(ClientMessage.createSession(name: "Client Test"))
        let createResp = try conn.receiveSync()

        if case .sessionCreated(let info) = createResp {
            #expect(info.name == "Client Test")
        } else {
            Issue.record("Expected sessionCreated, got \(createResp)")
        }

        conn.close()
        server.stop()
    }

    @Test("TYDConnection async read loop receives messages")
    func connectionAsyncReadLoop() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-async-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let socket = try TYSocket.connect(path: socketPath)
        let conn = TYDConnection(socket: socket)

        let receivedMessage = Mutex<ServerMessage?>(nil)
        let expectation = Mutex(false)

        conn.onMessage = { message in
            receivedMessage.withLock { $0 = message }
            expectation.withLock { $0 = true }
        }

        conn.startReadLoop()

        // Send a request; the response should arrive via onMessage.
        conn.send(ClientMessage.listSessions)

        // Wait for the response.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if expectation.withLock({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let msg = receivedMessage.withLock { $0 }
        if case .sessionList(let sessions) = msg {
            #expect(sessions.isEmpty)
        } else {
            Issue.record("Expected sessionList via async read, got \(String(describing: msg))")
        }

        conn.close()
        server.stop()
    }

    @Test("TYDConnection onDisconnect fires when connection closes")
    func connectionDisconnectCallback() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-disc-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let socket = try TYSocket.connect(path: socketPath)
        let conn = TYDConnection(socket: socket)

        let disconnected = Mutex(false)
        conn.onDisconnect = {
            disconnected.withLock { $0 = true }
        }
        conn.startReadLoop()
        Thread.sleep(forTimeInterval: 0.1)

        // Close the client connection — should trigger disconnect callback.
        conn.close()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if disconnected.withLock({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(disconnected.withLock { $0 } == true)
        server.stop()
    }

    // MARK: - RemoteSessionClient Tests

    @Test("RemoteSessionClient receives session list on connect")
    func remoteSessionClientConnect() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-remote-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let connManager = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client = RemoteSessionClient(connectionManager: connManager)

        let receivedSessions = Mutex<[SessionInfo]?>(nil)

        client.onSessionList = { sessions in
            receivedSessions.withLock { $0 = sessions }
        }

        try client.connect()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if receivedSessions.withLock({ $0 }) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let sessions = receivedSessions.withLock { $0 }
        #expect(sessions != nil)
        #expect(sessions?.isEmpty == true)

        client.disconnect()
        server.stop()
    }

    @Test("RemoteSessionClient creates session and receives notification")
    func remoteSessionClientCreateSession() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-create-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let connManager = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client = RemoteSessionClient(connectionManager: connManager)

        let createdSession = Mutex<SessionInfo?>(nil)

        client.onSessionCreated = { info in
            createdSession.withLock { $0 = info }
        }

        try client.connect()
        Thread.sleep(forTimeInterval: 0.2)

        client.createSession(name: "RemoteTest")

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if createdSession.withLock({ $0 }) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let info = createdSession.withLock { $0 }
        #expect(info != nil)
        #expect(info?.name == "RemoteTest")
        #expect(info?.tabs.count == 1)

        client.disconnect()
        server.stop()
    }

    @Test("RemoteSessionClient reconnect attaches and receives screen updates")
    func remoteSessionClientReconnect() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-reconnect-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        // --- First connection: create a session ---
        let connManager1 = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client1 = RemoteSessionClient(connectionManager: connManager1)

        let createdSession = Mutex<SessionInfo?>(nil)
        client1.onSessionCreated = { info in
            createdSession.withLock { $0 = info }
        }
        try client1.connect()
        Thread.sleep(forTimeInterval: 0.2)

        client1.createSession(name: "ReconnectTest")

        let deadline1 = Date().addingTimeInterval(2.0)
        while Date() < deadline1 {
            if createdSession.withLock({ $0 }) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let sessionInfo = createdSession.withLock { $0 }
        #expect(sessionInfo != nil)

        // Disconnect the first client.
        client1.disconnect()
        Thread.sleep(forTimeInterval: 0.2)

        // --- Second connection: should see existing session and attach ---
        let connManager2 = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client2 = RemoteSessionClient(connectionManager: connManager2)

        let receivedSessions = Mutex<[SessionInfo]?>(nil)
        let screenUpdated = Mutex(false)

        client2.onSessionList = { sessions in
            receivedSessions.withLock { $0 = sessions }
            // Attach to the existing session (mimics what addOrUpdateRemoteSession should do).
            for info in sessions {
                client2.attachSession(info.id)
            }
        }
        client2.onScreenUpdated = { _, _ in
            screenUpdated.withLock { $0 = true }
        }

        try client2.connect()

        // Wait for session list.
        let deadline2 = Date().addingTimeInterval(2.0)
        while Date() < deadline2 {
            if receivedSessions.withLock({ $0 }) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let sessions = receivedSessions.withLock { $0 }
        #expect(sessions?.count == 1)
        #expect(sessions?.first?.name == "ReconnectTest")

        // Wait for screen update after attach.
        let deadline3 = Date().addingTimeInterval(3.0)
        while Date() < deadline3 {
            if screenUpdated.withLock({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(screenUpdated.withLock { $0 } == true)

        client2.disconnect()
        server.stop()
    }

    @Test("RemoteSessionClient onDisconnected fires when server closes connection")
    func remoteSessionClientDisconnected() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-ondisconnect-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let connManager = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client = RemoteSessionClient(connectionManager: connManager)

        let disconnected = Mutex(false)
        client.onDisconnected = {
            disconnected.withLock { $0 = true }
        }

        try client.connect()
        Thread.sleep(forTimeInterval: 0.2)

        // Stop the server — should trigger client disconnect.
        server.stop()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if disconnected.withLock({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(disconnected.withLock { $0 } == true)

        client.disconnect()
    }

    @Test("RemoteSessionClient screen replica receives updates")
    func remoteSessionClientScreenUpdate() throws {
        let socketPath = NSTemporaryDirectory() + "tyc-screen-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath, autoExitOnNoSessions: false)
        let sessionManager = ServerSessionManager(defaultColumns: 80, defaultRows: 24)
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        let connManager = TYDConnectionManager(socketPath: socketPath, autoStart: false)
        let client = RemoteSessionClient(connectionManager: connManager)

        let screenUpdated = Mutex(false)
        var capturedPaneID: PaneID?

        client.onSessionCreated = { info in
            // Auto-attach to receive updates.
            client.attachSession(info.id)
        }

        client.onScreenUpdated = { _, paneID in
            capturedPaneID = paneID
            screenUpdated.withLock { $0 = true }
        }

        try client.connect()
        Thread.sleep(forTimeInterval: 0.2)

        client.createSession(name: "ScreenTest")

        // Wait for screen update (shell startup output).
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if screenUpdated.withLock({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        #expect(screenUpdated.withLock { $0 } == true)

        if let paneID = capturedPaneID {
            let replica = client.replica(for: paneID)
            let snapshot = replica.forceSnapshot()
            #expect(snapshot.columns == 80)
            #expect(snapshot.rows == 24)
        }

        client.disconnect()
        server.stop()
    }
}

/// Simple thread-safe wrapper for test assertions.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
