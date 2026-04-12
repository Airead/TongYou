import Testing
import Foundation
@testable import TYProtocol
@testable import TYTerminal

@Suite("TYSocket integration tests")
struct TYSocketTests {

    @Test func clientServerRoundTrip() throws {
        let socketPath = NSTemporaryDirectory() + "tytest_\(UUID().uuidString).sock"
        defer { unlink(socketPath) }

        // Start server
        let server = try TYSocket.listen(path: socketPath)
        defer { server.closeSocket() }

        // Connect client (in a thread since accept() is blocking)
        var acceptedClient: TYSocket?
        let acceptThread = Thread {
            acceptedClient = try? server.accept()
        }
        acceptThread.start()

        // Give server a moment to start accepting
        Thread.sleep(forTimeInterval: 0.05)

        let client = try TYSocket.connect(path: socketPath)
        defer { client.closeSocket() }

        // Wait for accept to complete
        Thread.sleep(forTimeInterval: 0.05)

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

        var acceptedClient: TYSocket?
        let acceptThread = Thread {
            acceptedClient = try? server.accept()
        }
        acceptThread.start()
        Thread.sleep(forTimeInterval: 0.05)

        let client = try TYSocket.connect(path: socketPath)
        defer { client.closeSocket() }
        Thread.sleep(forTimeInterval: 0.05)

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
}
