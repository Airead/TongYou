import Testing
import Foundation
@testable import TYAutomation
import TYProtocol

@Suite("GUI Automation Server", .serialized)
struct GUIAutomationServerTests {

    // MARK: - Helpers

    /// Build a fully isolated server configuration under a per-test temp dir.
    /// Paths never touch the user's real runtime directory.
    /// Uses `/tmp/` directly because macOS's `NSTemporaryDirectory` paths
    /// exceed the ~104-byte limit for Unix domain sockets.
    private static func isolatedConfig() -> (
        config: GUIAutomationServer.Configuration,
        tmpDir: String
    ) {
        let shortID = UUID().uuidString.prefix(8)
        let tmpDir = "/tmp/tyauto_\(shortID)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let socketPath = tmpDir + "/s.sock"
        let tokenPath = tmpDir + "/s.token"
        let config = GUIAutomationServer.Configuration(
            socketPath: socketPath,
            tokenPath: tokenPath,
            allowedPeerUID: getuid()
        )
        return (config, tmpDir)
    }

    private static func sendLine(_ socket: TYSocket, _ line: String) throws {
        let io = LineIO(fd: socket.fileDescriptor)
        try io.writeLine(line)
    }

    private static func readLine(_ socket: TYSocket) throws -> String? {
        let io = LineIO(fd: socket.fileDescriptor)
        return try io.readLine()
    }

    // MARK: - Token file permissions

    @Test func tokenFileHas0600Permissions() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        #expect(FileManager.default.fileExists(atPath: config.tokenPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: config.tokenPath)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o600, "token file should be 0600, got 0\(String(perms, radix: 8))")
    }

    @Test func socketFileHas0600Permissions() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        #expect(FileManager.default.fileExists(atPath: config.socketPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: config.socketPath)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o600, "socket file should be 0600, got 0\(String(perms, radix: 8))")
    }

    @Test func stopRemovesSocketAndTokenFiles() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()

        #expect(FileManager.default.fileExists(atPath: config.socketPath))
        #expect(FileManager.default.fileExists(atPath: config.tokenPath))

        server.stop()

        #expect(!FileManager.default.fileExists(atPath: config.socketPath))
        #expect(!FileManager.default.fileExists(atPath: config.tokenPath))
    }

    // MARK: - Handshake

    @Test func correctTokenAllowsPing() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        // Brief wait so the accept loop is ready.
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        let handshakeResp = try #require(try Self.readLine(socket))
        #expect(handshakeResp.contains("\"ok\":true"))

        try Self.sendLine(socket, #"{"cmd":"server.ping"}"#)
        let pingResp = try #require(try Self.readLine(socket))
        #expect(pingResp.contains("\"ok\":true"))
        #expect(pingResp.contains("\"result\":\"pong\""))
    }

    @Test func wrongTokenReturnsUnauthenticated() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"wrong-token"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"UNAUTHENTICATED\""))

        // After UNAUTHENTICATED the server closes the connection.
        let next = try Self.readLine(socket)
        #expect(next == nil, "connection should be closed after failed handshake")
    }

    @Test func commandBeforeHandshakeIsRejected() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"server.ping"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"UNAUTHENTICATED\""))
    }

    @Test func malformedJSONAfterHandshakeReturnsError() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, "not valid json")
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_REQUEST\""))
    }

    @Test func unknownCommandAfterHandshakeReturnsError() throws {
        let (config, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"bogus.command"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"UNKNOWN_COMMAND\""))
    }
}

// MARK: - Auth helpers

@Suite("GUI Automation Auth", .serialized)
struct GUIAutomationAuthTests {

    @Test func generateWritesHexTokenAt0600() throws {
        let tmpDir = NSTemporaryDirectory() + "tyauth_\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let tokenPath = tmpDir + "/tok"
        let token = try GUIAutomationAuth.generate(tokenPath: tokenPath)

        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })

        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = (attrs[.posixPermissions] as! NSNumber).uint16Value
        #expect(perms == 0o600)

        let readBack = GUIAutomationAuth.read(tokenPath: tokenPath)
        #expect(readBack == token)
    }

    @Test func removeDeletesFile() throws {
        let tmpDir = NSTemporaryDirectory() + "tyauth_\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let tokenPath = tmpDir + "/tok"
        _ = try GUIAutomationAuth.generate(tokenPath: tokenPath)
        #expect(FileManager.default.fileExists(atPath: tokenPath))

        GUIAutomationAuth.remove(tokenPath: tokenPath)
        #expect(!FileManager.default.fileExists(atPath: tokenPath))
    }
}

// MARK: - Path helpers

@Suite("GUI Automation Paths")
struct GUIAutomationPathsTests {

    @Test func tokenPathForSocketPathMatchesConvention() {
        let sock = "/tmp/gui-12345.sock"
        let expected = "/tmp/gui-12345.token"
        #expect(GUIAutomationPaths.tokenPath(forSocketPath: sock) == expected)
    }

    @Test func tokenPathReturnsNilForUnrelatedPath() {
        #expect(GUIAutomationPaths.tokenPath(forSocketPath: "/tmp/something.sock") == nil)
        #expect(GUIAutomationPaths.tokenPath(forSocketPath: "/tmp/gui-42.txt") == nil)
    }

    @Test func discoverSocketPathsScansDirectory() throws {
        let tmpDir = NSTemporaryDirectory() + "typaths_\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let files = ["gui-1.sock", "gui-2.sock", "other.sock", "gui-3.txt"]
        for f in files {
            let path = (tmpDir as NSString).appendingPathComponent(f)
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let found = GUIAutomationPaths.discoverSocketPaths(in: tmpDir)
        let names = Set(found.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["gui-1.sock", "gui-2.sock"])
    }
}
