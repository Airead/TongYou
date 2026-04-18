import Testing
import Foundation
@testable import TYServer
import TYProtocol
import TYTerminal

@Suite("Auth Tests", .serialized)
struct AuthTests {

    // MARK: - Token Generation

    @Test func generateAuthTokenCreatesFileWith0600() throws {
        let tmpDir = NSTemporaryDirectory() + "tyauth_\(UUID().uuidString)"
        let tokenPath = tmpDir + "/auth-token"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let lifecycle = DaemonLifecycle(
            pidPath: tmpDir + "/test.pid",
            socketPath: tmpDir + "/test.sock",
            tokenPath: tokenPath
        )
        let token = try lifecycle.generateAuthToken()

        // Token is 64 hex chars (32 bytes)
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })

        // File permissions should be 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o600, "Token file should have 0600 permissions, got \(String(perms, radix: 8))")

        // Read back should match
        let readBack = DaemonLifecycle.readAuthToken(from: tokenPath)
        #expect(readBack == token)
    }

    @Test func removeTokenFileDeletesFile() throws {
        let tmpDir = NSTemporaryDirectory() + "tyauth_\(UUID().uuidString)"
        let tokenPath = tmpDir + "/auth-token"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let lifecycle = DaemonLifecycle(
            pidPath: tmpDir + "/test.pid",
            socketPath: tmpDir + "/test.sock",
            tokenPath: tokenPath
        )
        try lifecycle.generateAuthToken()
        #expect(FileManager.default.fileExists(atPath: tokenPath))

        lifecycle.removeTokenFile()
        #expect(!FileManager.default.fileExists(atPath: tokenPath))
    }

    // MARK: - Handshake Protocol

    @Test func correctTokenHandshakeSucceeds() throws {
        let socketPath = NSTemporaryDirectory() + "tyhs_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let token = "test-secret-token-12345"
        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager, authToken: token)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { server.stop() }

        let clientSocket = try TYSocket.connect(path: socketPath)
        defer { clientSocket.closeSocket() }

        // Send handshake with correct token
        try clientSocket.send(ClientMessage.handshake(token: token))
        let response = try clientSocket.receiveServerMessage()

        guard case .handshakeResult(let success) = response else {
            Issue.record("Expected handshakeResult, got \(response)")
            return
        }
        #expect(success == true)

        // After successful handshake, normal messages should work
        try clientSocket.send(ClientMessage.listSessions)
        let listResponse = try clientSocket.receiveServerMessage()
        guard case .sessionList = listResponse else {
            Issue.record("Expected sessionList, got \(listResponse)")
            return
        }
    }

    @Test func wrongTokenHandshakeFails() throws {
        let socketPath = NSTemporaryDirectory() + "tyhs_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let token = "correct-token"
        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager, authToken: token)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { server.stop() }

        let clientSocket = try TYSocket.connect(path: socketPath)
        defer { clientSocket.closeSocket() }

        // Send handshake with wrong token
        try clientSocket.send(ClientMessage.handshake(token: "wrong-token"))
        let response = try clientSocket.receiveServerMessage()

        guard case .handshakeResult(let success) = response else {
            Issue.record("Expected handshakeResult, got \(response)")
            return
        }
        #expect(success == false)

        // Connection should be closed by the server — next read should fail
        #expect(throws: (any Error).self) {
            _ = try clientSocket.receiveServerMessage()
        }
    }

    @Test func messageBeforeHandshakeIsRejected() throws {
        let socketPath = NSTemporaryDirectory() + "tyhs_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let token = "secret-token"
        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager, authToken: token)

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { server.stop() }

        let clientSocket = try TYSocket.connect(path: socketPath)
        defer { clientSocket.closeSocket() }

        // Send a non-handshake message first
        try clientSocket.send(ClientMessage.listSessions)
        let response = try clientSocket.receiveServerMessage()

        guard case .handshakeResult(let success) = response else {
            Issue.record("Expected handshakeResult, got \(response)")
            return
        }
        #expect(success == false)

        // Connection should be closed
        #expect(throws: (any Error).self) {
            _ = try clientSocket.receiveServerMessage()
        }
    }

    @Test func noTokenRequiredWhenServerHasNoAuth() throws {
        let socketPath = NSTemporaryDirectory() + "tyhs_\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let config = ServerConfig(socketPath: socketPath)
        let sessionManager = ServerSessionManager()
        let server = SocketServer(config: config, sessionManager: sessionManager)
        // No setAuthToken called — handshake not required

        try server.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { server.stop() }

        let clientSocket = try TYSocket.connect(path: socketPath)
        defer { clientSocket.closeSocket() }

        // Should work without handshake
        try clientSocket.send(ClientMessage.listSessions)
        let response = try clientSocket.receiveServerMessage()
        guard case .sessionList = response else {
            Issue.record("Expected sessionList, got \(response)")
            return
        }
    }
}
