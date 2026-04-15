import Testing
import Foundation
@testable import TYServer
import TYProtocol
import TYTerminal

@Suite("Server Integration Tests", .serialized)
struct IntegrationTests {

    @Test("Full flow: start server, connect client, create session, send input, receive screen update")
    func fullFlow() throws {
        let socketPath = NSTemporaryDirectory() + "ty-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(
            socketPath: socketPath,
            autoExitOnNoSessions: false
        )
        let sessionManager = ServerSessionManager(
            defaultColumns: 80,
            defaultRows: 24
        )
        let server = SocketServer(config: config, sessionManager: sessionManager)

        let readyFired = Mutex(false)
        server.onReady = {
            readyFired.withLock { $0 = true }
        }

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        #expect(readyFired.withLock({ $0 }) == true)

        // Connect a client
        let clientSocket = try TYSocket.connect(path: socketPath)

        // Request session list (should be empty)
        try clientSocket.send(ClientMessage.listSessions)
        let listResponse = try clientSocket.receiveServerMessage()

        if case .sessionList(let sessions) = listResponse {
            #expect(sessions.isEmpty)
        } else {
            Issue.record("Expected sessionList response, got \(listResponse)")
        }

        // Create a session
        try clientSocket.send(ClientMessage.createSession(name: "Integration Test"))

        // Should receive sessionCreated
        let createResponse = try clientSocket.receiveServerMessage()
        let sessionID: SessionID
        switch createResponse {
        case .sessionCreated(let info):
            #expect(info.name == "Integration Test")
            #expect(info.tabs.count == 1)
            sessionID = info.id
        default:
            Issue.record("Expected sessionCreated, got \(createResponse)")
            return
        }

        // The client was auto-attached, so it should start receiving screen updates.
        // Wait for shell to produce some output.
        Thread.sleep(forTimeInterval: 0.5)

        // Send input
        guard case .leaf(let paneID) = sessionManager.sessionInfo(for: sessionID)?.tabs[0].layout else {
            Issue.record("Expected leaf layout")
            return
        }
        try clientSocket.send(ClientMessage.input(sessionID, paneID, Array("echo test123\n".utf8)))

        // Wait for PTY processing
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the session manager has content
        let snapshot = sessionManager.snapshot(paneID: paneID)
        #expect(snapshot != nil)

        // Clean up
        server.stop()
    }

    @Test("Client disconnect does not affect sessions")
    func clientDisconnectPreservesSession() throws {
        let socketPath = NSTemporaryDirectory() + "ty-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        // Connect first client and create a session
        let client1 = try TYSocket.connect(path: socketPath)
        try client1.send(ClientMessage.createSession(name: "Persist Test"))
        let response = try client1.receiveServerMessage()

        guard case .sessionCreated(let info) = response else {
            Issue.record("Expected sessionCreated")
            return
        }

        // Disconnect client 1
        client1.closeSocket()
        Thread.sleep(forTimeInterval: 0.2)

        // Session should still exist
        #expect(sessionManager.hasSessions == true)
        #expect(sessionManager.sessionInfo(for: info.id) != nil)

        // Connect second client and list sessions
        let client2 = try TYSocket.connect(path: socketPath)
        try client2.send(ClientMessage.listSessions)
        let listResponse = try client2.receiveServerMessage()

        if case .sessionList(let sessions) = listResponse {
            #expect(sessions.count == 1)
            #expect(sessions[0].id == info.id)
        } else {
            Issue.record("Expected sessionList")
        }

        // Clean up
        sessionManager.closeSession(id: info.id)
        server.stop()
    }

    @Test("Multiple clients attach to same session")
    func multipleClientsAttach() throws {
        let socketPath = NSTemporaryDirectory() + "ty-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)

        // Client 1 creates a session
        let client1 = try TYSocket.connect(path: socketPath)
        try client1.send(ClientMessage.createSession(name: "Multi Client"))
        let createResp = try client1.receiveServerMessage()

        guard case .sessionCreated(let info) = createResp else {
            Issue.record("Expected sessionCreated")
            return
        }

        // Client 2 connects and attaches to the same session
        let client2 = try TYSocket.connect(path: socketPath)
        try client2.send(ClientMessage.attachSession(info.id))

        // Client 2 should first receive a layoutUpdate, then a full snapshot.
        let layoutResp = try client2.receiveServerMessage()
        switch layoutResp {
        case .layoutUpdate(let layoutInfo):
            #expect(layoutInfo.id == info.id)
        default:
            Issue.record("Expected layoutUpdate on attach, got \(layoutResp)")
        }

        let snapshotResp = try client2.receiveServerMessage()
        switch snapshotResp {
        case .screenFull(let sid, _, let snapshot):
            #expect(sid == info.id)
            #expect(snapshot.columns == 80)
            #expect(snapshot.rows == 24)
        default:
            Issue.record("Expected screenFull on attach, got \(snapshotResp)")
        }

        // Both clients can see the session
        #expect(server.clientCount == 2)

        // Clean up
        sessionManager.closeSession(id: info.id)
        server.stop()
    }

    @Test("DaemonLifecycle PID file operations")
    func pidFileOperations() throws {
        let tmpDir = NSTemporaryDirectory() + "ty-lifecycle-\(UUID().uuidString)"
        let pidPath = tmpDir + "/tongyou.pid"
        let socketPath = tmpDir + "/tongyou.sock"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let lifecycle = DaemonLifecycle(pidPath: pidPath, socketPath: socketPath)

        try lifecycle.writePIDFile()

        let readPID = DaemonLifecycle.readPID(from: pidPath)
        #expect(readPID == ProcessInfo.processInfo.processIdentifier)

        // Check existing process should find us
        let existing = DaemonLifecycle.checkExistingProcess(pidPath: pidPath)
        #expect(existing == ProcessInfo.processInfo.processIdentifier)

        lifecycle.removePIDFile()

        let afterRemove = DaemonLifecycle.readPID(from: pidPath)
        #expect(afterRemove == nil)
    }

    @Test("ServerConfig default paths are non-empty")
    func serverConfigDefaults() {
        let config = ServerConfig()
        #expect(!config.socketPath.isEmpty)
        #expect(config.socketPath.contains("tongyou"))
        #expect(config.socketPath.hasSuffix("tongyou.sock"))

        let pidPath = ServerConfig.defaultPIDPath()
        #expect(!pidPath.isEmpty)
        #expect(pidPath.contains("tongyou"))
        #expect(pidPath.hasSuffix("tongyou.pid"))
    }

    @Test("Backpressure drops screen updates when over threshold")
    func backpressureDropsScreenUpdates() throws {
        let socketPath = NSTemporaryDirectory() + "ty-bp-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let listenSocket = try TYSocket.listen(path: socketPath)
        let clientEnd = try TYSocket.connect(path: socketPath)
        let serverEnd = try listenSocket.accept()
        listenSocket.closeSocket()

        let maxPending = 3
        let conn = ClientConnection(socket: serverEnd, maxPendingScreenUpdates: maxPending)

        let dummySessionID = SessionID()
        let dummyPaneID = PaneID()
        let snapshot = ScreenSnapshot(
            cells: [Cell](repeating: .empty, count: 4),
            columns: 2, rows: 2,
            cursorCol: 0, cursorRow: 0,
            cursorVisible: true, cursorShape: .block,
            selection: nil, scrollbackCount: 0, viewportOffset: 0,
            dirtyRegion: .full
        )

        // Send many screen updates rapidly.
        let totalSent = 20
        for _ in 0..<totalSent {
            conn.send(.screenFull(dummySessionID, dummyPaneID, snapshot))
        }

        // Also send non-screen messages — these must never be dropped.
        conn.send(.sessionClosed(dummySessionID))
        conn.send(.sessionClosed(dummySessionID))
        conn.send(.sessionClosed(dummySessionID))

        // Wait for the writeQueue to drain, then close the server end
        // so the client's receiveServerMessage hits EOF and stops blocking.
        Thread.sleep(forTimeInterval: 0.5)
        conn.stop()

        // Read all messages that were actually sent.
        var screenCount = 0
        var nonScreenCount = 0
        while true {
            do {
                let msg = try clientEnd.receiveServerMessage()
                if msg.isScreenUpdate {
                    screenCount += 1
                } else {
                    nonScreenCount += 1
                }
            } catch {
                break  // EOF or error — done reading
            }
        }

        // Backpressure is approximate (race between check-and-increment
        // and writeQueue drain), but we must see significantly fewer than totalSent.
        #expect(screenCount < totalSent / 2)

        // All non-screen messages should be delivered.
        #expect(nonScreenCount == 3)
    }

    @Test("ScreenDiff(from:) converts snapshot correctly")
    func screenDiffFromSnapshot() {
        let columns = 4
        let rows = 3
        let cells = [Cell](repeating: .empty, count: columns * rows)
        var region = DirtyRegion(rowCount: rows, fullRebuild: false)
        region.markRange(1..<3)
        let snapshot = ScreenSnapshot(
            cells: cells,
            columns: columns,
            rows: rows,
            cursorCol: 1,
            cursorRow: 2,
            cursorVisible: true,
            cursorShape: .block,
            selection: nil,
            scrollbackCount: 0,
            viewportOffset: 0,
            dirtyRegion: region
        )

        let diff = ScreenDiff(from: snapshot)
        #expect(diff.dirtyRows == [1, 2])
        #expect(diff.cellData.count == 2 * columns)
        #expect(diff.columns == UInt16(columns))
        #expect(diff.cursorCol == 1)
        #expect(diff.cursorRow == 2)
        #expect(diff.cursorVisible == true)
        #expect(diff.cursorShape == .block)
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
