#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Foundation
import TYProtocol
import TYServer

/// Errors raised during server startup.
public enum GUIAutomationServerError: Error {
    case alreadyRunning
    case socketBindFailed(underlying: Error)
    case tokenGenerationFailed(underlying: Error)
    case runtimeDirectorySetupFailed(underlying: Error)
}

/// JSON-line Unix-socket server used by the GUI app to expose script
/// automation commands. Mirrors the daemon's three-layer security:
/// file perms (0700 dir / 0600 sock+token), `getpeereid()` UID check,
/// and token-based handshake.
public final class GUIAutomationServer: @unchecked Sendable {

    /// Runtime configuration for the server.
    public struct Configuration: Sendable {
        public let socketPath: String
        public let tokenPath: String
        public let allowedPeerUID: uid_t

        public init(
            socketPath: String = GUIAutomationPaths.socketPath(),
            tokenPath: String = GUIAutomationPaths.tokenPath(),
            allowedPeerUID: uid_t = getuid()
        ) {
            self.socketPath = socketPath
            self.tokenPath = tokenPath
            self.allowedPeerUID = allowedPeerUID
        }
    }

    private let config: Configuration
    private let stateLock = NSLock()
    private var listener: TYSocket?
    private var token: String = ""
    private var running = false

    private let acceptQueue = DispatchQueue(
        label: "io.github.airead.tongyou.automation.accept"
    )

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    // MARK: - Lifecycle

    /// Start the server: ensure runtime dir, generate token, bind socket,
    /// and spawn the accept loop.
    public func start() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            throw GUIAutomationServerError.alreadyRunning
        }
        stateLock.unlock()

        do {
            try GUIAutomationPaths.ensureRuntimeDirectory()
        } catch {
            throw GUIAutomationServerError.runtimeDirectorySetupFailed(underlying: error)
        }

        let generatedToken: String
        do {
            generatedToken = try GUIAutomationAuth.generate(tokenPath: config.tokenPath)
        } catch {
            throw GUIAutomationServerError.tokenGenerationFailed(underlying: error)
        }

        let listener: TYSocket
        do {
            // TYSocket.listen() unlinks stale file, binds, chmods 0600, listens.
            listener = try TYSocket.listen(path: config.socketPath)
        } catch {
            GUIAutomationAuth.remove(tokenPath: config.tokenPath)
            throw GUIAutomationServerError.socketBindFailed(underlying: error)
        }

        stateLock.lock()
        self.listener = listener
        self.token = generatedToken
        self.running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        Log.info("GUI automation server listening at \(config.socketPath)")
    }

    /// Stop the server: close the listener, remove socket/token files.
    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let listenerToClose = listener
        listener = nil
        token = ""
        stateLock.unlock()

        listenerToClose?.closeSocket()

        // Remove socket file (unlink; TYSocket.listen doesn't auto-clean on close).
        try? FileManager.default.removeItem(atPath: config.socketPath)
        GUIAutomationAuth.remove(tokenPath: config.tokenPath)

        if wasRunning {
            Log.info("GUI automation server stopped")
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stillRunning = running
            let activeListener = listener
            stateLock.unlock()
            guard stillRunning, let activeListener else { return }

            let client: TYSocket
            do {
                client = try activeListener.accept()
            } catch {
                // `accept()` returns an error when we close the listener fd.
                stateLock.lock()
                let shouldExit = !running
                stateLock.unlock()
                if shouldExit { return }
                Log.warning("GUI automation accept failed: \(error)")
                continue
            }

            // Layer 2: peer credential check.
            do {
                let peer = try client.peerCredentials()
                if peer.uid != config.allowedPeerUID {
                    Log.warning(
                        "GUI automation: rejecting connection from uid=\(peer.uid) (expected \(config.allowedPeerUID))"
                    )
                    client.closeSocket()
                    continue
                }
            } catch {
                Log.warning("GUI automation: peer credential check failed: \(error)")
                client.closeSocket()
                continue
            }

            let expectedToken = currentToken()
            let connQueue = DispatchQueue(
                label: "io.github.airead.tongyou.automation.conn"
            )
            connQueue.async {
                GUIAutomationServer.handleConnection(client, expectedToken: expectedToken)
            }
        }
    }

    private func currentToken() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return token
    }

    // MARK: - Connection Handler

    private enum ConnectionState {
        case awaitingHandshake
        case authenticated
    }

    private static func handleConnection(_ socket: TYSocket, expectedToken: String) {
        defer { socket.closeSocket() }

        let io = LineIO(fd: socket.fileDescriptor)
        var state: ConnectionState = .awaitingHandshake

        while true {
            let line: String?
            do {
                line = try io.readLine()
            } catch {
                return
            }
            guard let rawLine = line else { return }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let request: ParsedRequest
            switch parseRequest(trimmed) {
            case .success(let req):
                request = req
            case .failure:
                tryWrite(io: io, errorCode: "INVALID_REQUEST", message: "malformed JSON request")
                continue
            }

            switch state {
            case .awaitingHandshake:
                guard request.cmd == "handshake" else {
                    tryWrite(io: io, errorCode: "UNAUTHENTICATED", message: "handshake required")
                    return
                }
                guard let token = request.token, token == expectedToken, !expectedToken.isEmpty else {
                    tryWrite(io: io, errorCode: "UNAUTHENTICATED", message: "invalid token")
                    return
                }
                state = .authenticated
                tryWrite(io: io, success: .string("ok"))

            case .authenticated:
                let response = dispatch(request: request)
                tryWrite(io: io, response: response)
            }
        }
    }

    private static func dispatch(request: ParsedRequest) -> JSONResponse {
        switch request.cmd {
        case "handshake":
            // Idempotent: already authenticated.
            return .success(.string("ok"))
        case "server.ping":
            return .success(.string("pong"))
        default:
            return .error(code: "UNKNOWN_COMMAND", message: "unknown command: \(request.cmd)")
        }
    }

    // MARK: - JSON helpers

    private struct ParsedRequest {
        let cmd: String
        let token: String?
    }

    private enum JSONResponse {
        case success(JSONValue)
        case error(code: String, message: String)
    }

    /// Minimal JSON value used for response payloads.
    enum JSONValue {
        case string(String)
        case null
    }

    private static func parseRequest(_ line: String) -> Result<ParsedRequest, Error> {
        struct ParseError: Error {}
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return .failure(ParseError())
        }
        let token = obj["token"] as? String
        return .success(ParsedRequest(cmd: cmd, token: token))
    }

    private static func encode(response: JSONResponse) -> String {
        switch response {
        case .success(let value):
            let resultFragment: String
            switch value {
            case .null:
                resultFragment = "null"
            case .string(let s):
                resultFragment = jsonEncodeString(s)
            }
            return #"{"ok":true,"result":\#(resultFragment)}"#
        case .error(let code, let message):
            return #"{"ok":false,"error":{"code":\#(jsonEncodeString(code)),"message":\#(jsonEncodeString(message))}}"#
        }
    }

    private static func jsonEncodeString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        // JSONSerialization wraps the string in an array; extract the inner form.
        guard let serialized = String(data: data, encoding: .utf8) else { return "\"\"" }
        // Trim leading '[' and trailing ']'.
        guard serialized.count >= 2 else { return "\"\"" }
        return String(serialized.dropFirst().dropLast())
    }

    private static func tryWrite(io: LineIO, response: JSONResponse) {
        let encoded = encode(response: response)
        try? io.writeLine(encoded)
    }

    private static func tryWrite(io: LineIO, success value: JSONValue) {
        tryWrite(io: io, response: .success(value))
    }

    private static func tryWrite(io: LineIO, errorCode: String, message: String) {
        tryWrite(io: io, response: .error(code: errorCode, message: message))
    }
}
