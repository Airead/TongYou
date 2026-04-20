import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal

@Suite("TYSocket integration tests", .serialized)
struct TYSocketTests {

    @Test func clientServerRoundTrip() throws {
        let socketPath = NSTemporaryDirectory() + "tytest_\(UUID().uuidString).sock"
        defer { unlink(socketPath) }

        // Start server
        let server = try TYSocket.listen(path: socketPath)
        defer { server.closeSocket() }

        // Connect client (in a thread since accept() is blocking).
        // The semaphore establishes a happens-before edge between the
        // accepting thread's write and the main thread's read — a plain
        // `Thread.sleep` races (TSan will flag it).
        nonisolated(unsafe) var acceptedClient: TYSocket?
        let acceptDone = DispatchSemaphore(value: 0)
        let acceptThread = Thread {
            acceptedClient = try? server.accept()
            acceptDone.signal()
        }
        acceptThread.start()

        let client = try TYSocket.connect(path: socketPath)
        defer { client.closeSocket() }

        acceptDone.wait()

        guard let serverSide = acceptedClient else {
            Issue.record("Server failed to accept connection")
            return
        }
        defer { serverSide.closeSocket() }

        // Client sends a message
        let sid = SessionID()
        let pid = PaneID()
        let inputBytes: [UInt8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F]  // "hello"
        try client.send(ClientMessage.input(sid, pid, inputBytes))

        // Server receives the message
        let frame = try serverSide.receiveFrame()
        let decoded = try WireFormat.decodeClientMessage(frame)

        guard case .input(let dSid, let dPid, let dBytes) = decoded else {
            Issue.record("Expected .input, got \(decoded)")
            return
        }
        #expect(dSid == sid)
        #expect(dPid == pid)
        #expect(dBytes == inputBytes)

        // Server sends a response
        try serverSide.send(ServerMessage.bell(sid, pid))

        // Client receives the response
        let serverMsg = try client.receiveServerMessage()
        guard case .bell(let rSid, let rPid) = serverMsg else {
            Issue.record("Expected .bell, got \(serverMsg)")
            return
        }
        #expect(rSid == sid)
        #expect(rPid == pid)
    }

    @Test func pathTooLong() throws {
        let longPath = String(repeating: "a", count: 200)
        #expect(throws: TYSocketError.self) {
            _ = try TYSocket.listen(path: longPath)
        }
    }

    @Test func connectToNonexistentSocket() throws {
        let badPath = NSTemporaryDirectory() + "tytest_nonexistent_\(UUID().uuidString).sock"
        #expect(throws: TYSocketError.self) {
            _ = try TYSocket.connect(path: badPath)
        }
    }

    @Test func multipleFramesInSequence() throws {
        let socketPath = NSTemporaryDirectory() + "tytest_multi_\(UUID().uuidString).sock"
        defer { unlink(socketPath) }

        let server = try TYSocket.listen(path: socketPath)
        defer { server.closeSocket() }

        nonisolated(unsafe) var acceptedClient: TYSocket?
        let acceptDone = DispatchSemaphore(value: 0)
        let acceptThread = Thread {
            acceptedClient = try? server.accept()
            acceptDone.signal()
        }
        acceptThread.start()

        let client = try TYSocket.connect(path: socketPath)
        defer { client.closeSocket() }

        acceptDone.wait()

        guard let serverSide = acceptedClient else {
            Issue.record("Server failed to accept connection")
            return
        }
        defer { serverSide.closeSocket() }

        // Send multiple messages
        let sid = SessionID()
        try client.send(ClientMessage.listSessions)
        try client.send(ClientMessage.createSession(name: "test"))
        try client.send(ClientMessage.attachSession(sid))

        // Receive them in order
        let msg1 = try WireFormat.decodeClientMessage(try serverSide.receiveFrame())
        let msg2 = try WireFormat.decodeClientMessage(try serverSide.receiveFrame())
        let msg3 = try WireFormat.decodeClientMessage(try serverSide.receiveFrame())

        guard case .listSessions = msg1 else {
            Issue.record("Expected .listSessions")
            return
        }
        guard case .createSession(let name) = msg2 else {
            Issue.record("Expected .createSession")
            return
        }
        #expect(name == "test")
        guard case .attachSession(let id) = msg3 else {
            Issue.record("Expected .attachSession")
            return
        }
        #expect(id == sid)
    }

    @Test func peerCredentialsReturnsCurrentUID() throws {
        let socketPath = NSTemporaryDirectory() + "typeer_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let server = try TYSocket.listen(path: socketPath)
        defer { server.closeSocket() }

        nonisolated(unsafe) var acceptedClient: TYSocket?
        let acceptDone = DispatchSemaphore(value: 0)
        let acceptThread = Thread {
            acceptedClient = try? server.accept()
            acceptDone.signal()
        }
        acceptThread.start()

        let client = try TYSocket.connect(path: socketPath)
        defer { client.closeSocket() }

        acceptDone.wait()

        guard let serverSide = acceptedClient else {
            Issue.record("Server failed to accept connection")
            return
        }
        defer { serverSide.closeSocket() }

        let (uid, _) = try serverSide.peerCredentials()
        #expect(uid == getuid(), "Peer UID should match current process UID")
    }

    @Test func socketFilePermissionsAreOwnerOnly() throws {
        let socketPath = NSTemporaryDirectory() + "typerm_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let server = try TYSocket.listen(path: socketPath)
        defer { server.closeSocket() }

        // Verify socket file has 0600 permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o600, "Socket file should have 0600 permissions, got \(String(perms, radix: 8))")
    }
}
