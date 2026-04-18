import Testing
import Foundation
@testable import TYAutomation
import TYProtocol
import TYTerminal

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

    // MARK: - session.list

    @Test func sessionListWithoutHandlerReturnsEmptyArray() throws {
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

        try Self.sendLine(socket, #"{"cmd":"session.list"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(resp.contains("\"sessions\":[]"))
    }

    // MARK: - session.create / close / attach

    @Test func sessionCreateReturnsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionCreate: { name, type in
                #expect(type == .local)
                let ref = name ?? "sess:1"
                return .success(SessionCreateResponse(ref: ref))
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.create","name":"dev","type":"local"}"#)
        let resp = try #require(try Self.readLine(socket))
        struct Envelope: Decodable { let result: SessionCreateResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(resp.utf8))
        #expect(envelope.result.ref == "dev")
    }

    @Test func sessionCreateRejectsBadType() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionCreate: { _, _ in .success(SessionCreateResponse(ref: "x")) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.create","type":"bogus"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func sessionCloseRequiresRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionClose: { _ in .success(()) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.close"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func sessionCloseForwardsRefToHandler() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable {
            var ref: String?
        }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionClose: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.close","ref":"dev"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev")
    }

    @Test func sessionDetachForwardsRefToHandler() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable {
            var ref: String?
        }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionDetach: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.detach","ref":"prod"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "prod")
    }

    @Test func sessionDetachPropagatesHandlerError() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionDetach: { _ in .failure(.sessionNotFound("ghost")) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.detach","ref":"ghost"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"SESSION_NOT_FOUND\""))
    }

    @Test func sessionDetachRequiresRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionDetach: { _ in .success(()) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.detach"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func sessionAttachOnLocalReturnsUnsupported() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionAttach: { _ in
                .failure(.unsupportedOperation("cannot attach a local session"))
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.attach","ref":"dev"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"UNSUPPORTED_OPERATION\""))
    }

    @Test func sessionCreatePropagatesHandlerError() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionCreate: { _, _ in .failure(.mainThreadTimeout) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.create","type":"remote"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"MAIN_THREAD_TIMEOUT\""))
    }

    // MARK: - tab.create / tab.select / tab.close

    @Test func tabCreateReturnsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleTabCreate: { ref in
                captured.ref = ref
                return .success(TabCreateResponse(ref: "\(ref)/tab:1"))
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"tab.create","ref":"dev"}"#)
        let resp = try #require(try Self.readLine(socket))
        struct Envelope: Decodable { let result: TabCreateResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(resp.utf8))
        #expect(envelope.result.ref == "dev/tab:1")
        #expect(captured.ref == "dev")
    }

    @Test func tabCreateRequiresRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleTabCreate: { _ in .success(TabCreateResponse(ref: "x")) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"tab.create"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func tabSelectForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleTabSelect: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"tab.select","ref":"dev/tab:2"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/tab:2")
    }

    @Test func tabClosePropagatesError() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleTabClose: { _ in .failure(.tabNotFound("dev/tab:9")) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"tab.close","ref":"dev/tab:9"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"TAB_NOT_FOUND\""))
    }

    // MARK: - pane.split / pane.focus / pane.close / pane.resize

    @Test func paneSplitParsesDirectionAndReturnsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable {
            var ref: String?
            var direction: SplitDirection?
        }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneSplit: { ref, dir in
                captured.ref = ref
                captured.direction = dir
                return .success(PaneSplitResponse(ref: "dev/pane:2"))
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.split","ref":"dev","direction":"horizontal"}"#)
        let resp = try #require(try Self.readLine(socket))
        struct Envelope: Decodable { let result: PaneSplitResponse }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(resp.utf8))
        #expect(envelope.result.ref == "dev/pane:2")
        #expect(captured.ref == "dev")
        #expect(captured.direction == .horizontal)
    }

    @Test func paneSplitRejectsBadDirection() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneSplit: { _, _ in .success(PaneSplitResponse(ref: "x")) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.split","ref":"dev","direction":"diagonal"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func paneFocusForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneFocus: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.focus","ref":"dev/pane:3"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/pane:3")
    }

    @Test func windowFocusInvokesHandler() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var called = 0 }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleWindowFocus: {
                captured.called += 1
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"window.focus"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(resp.contains("\"result\":null"))
        #expect(captured.called == 1)
    }

    @Test func windowFocusWithoutHandlerReturnsInternalError() throws {
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

        try Self.sendLine(socket, #"{"cmd":"window.focus"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INTERNAL_ERROR\""))
    }

    @Test func paneCloseForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneClose: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.close","ref":"dev/pane:2"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/pane:2")
    }

    @Test func paneResizeForwardsValue() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable {
            var ref: String?
            var ratio: Double?
        }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneResize: { ref, ratio in
                captured.ref = ref
                captured.ratio = ratio
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.resize","ref":"dev/pane:1","ratio":0.3}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/pane:1")
        if let r = captured.ratio {
            #expect(abs(r - 0.3) < 1e-9)
        } else {
            Issue.record("ratio was not captured")
        }
    }

    @Test func paneResizeRejectsOutOfRange() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handlePaneResize: { _, _ in .success(()) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"pane.resize","ref":"dev/pane:1","ratio":1.5}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    // MARK: - floatPane.create / focus / close / pin / move

    @Test func floatPaneCreateReturnsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPaneCreate: { ref in
                captured.ref = ref
                return .success(FloatPaneCreateResponse(ref: "dev/float:1"))
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"floatPane.create","ref":"dev"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(resp.contains("dev/float:1") || resp.contains(#"dev\/float:1"#))
        #expect(captured.ref == "dev")
    }

    @Test func floatPaneFocusForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPaneFocus: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"floatPane.focus","ref":"dev/float:2"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/float:2")
    }

    @Test func floatPaneCloseForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPaneClose: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"floatPane.close","ref":"dev/float:1"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/float:1")
    }

    @Test func floatPanePinForwardsRef() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable { var ref: String? }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPanePin: { ref in
                captured.ref = ref
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"floatPane.pin","ref":"dev/float:1"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/float:1")
    }

    @Test func floatPaneMoveForwardsFrame() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        final class Captured: @unchecked Sendable {
            var ref: String?
            var frame: FloatPaneFrame?
        }
        let captured = Captured()

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPaneMove: { ref, frame in
                captured.ref = ref
                captured.frame = frame
                return .success(())
            }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(
            socket,
            #"{"cmd":"floatPane.move","ref":"dev/float:1","x":0.1,"y":0.2,"width":0.3,"height":0.4}"#
        )
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))
        #expect(captured.ref == "dev/float:1")
        let frame = try #require(captured.frame)
        #expect(abs(frame.x - 0.1) < 1e-9)
        #expect(abs(frame.y - 0.2) < 1e-9)
        #expect(abs(frame.width - 0.3) < 1e-9)
        #expect(abs(frame.height - 0.4) < 1e-9)
    }

    @Test func floatPaneMoveRejectsFrameOutOfRange() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleFloatPaneMove: { _, _ in .success(()) }
        )
        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))
        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        // width + x exceeds 1 — must be rejected before reaching the handler.
        try Self.sendLine(
            socket,
            #"{"cmd":"floatPane.move","ref":"dev/float:1","x":0.8,"y":0.0,"width":0.5,"height":0.1}"#
        )
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"code\":\"INVALID_PARAMS\""))
    }

    @Test func sessionListRoutesThroughMainActorHandler() throws {
        let (baseConfig, tmpDir) = Self.isolatedConfig()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let config = GUIAutomationServer.Configuration(
            socketPath: baseConfig.socketPath,
            tokenPath: baseConfig.tokenPath,
            allowedPeerUID: baseConfig.allowedPeerUID,
            handleSessionList: {
                let tab = TabDescriptor(
                    ref: "demo/tab:1",
                    title: "Shell",
                    active: true,
                    panes: ["demo/pane:1"],
                    floats: []
                )
                let session = SessionDescriptor(
                    ref: "demo",
                    name: "demo",
                    type: .local,
                    state: .ready,
                    active: true,
                    tabs: [tab]
                )
                return SessionListResponse(sessions: [session])
            }
        )

        let server = GUIAutomationServer(configuration: config)
        try server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let token = try #require(GUIAutomationAuth.read(tokenPath: config.tokenPath))

        let socket = try TYSocket.connect(path: config.socketPath)
        defer { socket.closeSocket() }

        try Self.sendLine(socket, #"{"cmd":"handshake","token":"\#(token)"}"#)
        _ = try Self.readLine(socket)

        try Self.sendLine(socket, #"{"cmd":"session.list"}"#)
        let resp = try #require(try Self.readLine(socket))
        #expect(resp.contains("\"ok\":true"))

        // Decode the response and check the structured payload rather
        // than relying on JSONEncoder's escaping of '/'.
        struct Envelope: Decodable {
            let result: SessionListResponse
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(resp.utf8))
        #expect(envelope.result.sessions.count == 1)
        let session = try #require(envelope.result.sessions.first)
        #expect(session.ref == "demo")
        #expect(session.state == .ready)
        #expect(session.tabs.count == 1)
        #expect(session.tabs[0].ref == "demo/tab:1")
        #expect(session.tabs[0].panes == ["demo/pane:1"])
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
