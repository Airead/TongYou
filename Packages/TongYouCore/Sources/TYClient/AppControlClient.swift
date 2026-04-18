import Foundation
import TYAutomation
import TYProtocol

/// Errors surfaced by `AppControlClient`.
public enum AppControlError: Error {
    case guiNotRunning
    case tokenFileMissing(path: String)
    case handshakeFailed(reason: String)
    case transport(underlying: Error)
    case invalidResponse(raw: String)
    case serverError(code: String, message: String)
}

/// Client for the GUI automation socket.
///
/// Phase 1 surface: `ping()` and an extension seam for future commands.
/// Discovers the GUI socket by scanning the runtime directory for
/// `gui-*.sock` files and picking the first one that accepts a connection.
public final class AppControlClient {

    private let socket: TYSocket
    private let io: LineIO
    private(set) var isAuthenticated = false

    private init(socket: TYSocket) {
        self.socket = socket
        self.io = LineIO(fd: socket.fileDescriptor)
    }

    deinit {
        socket.closeSocket()
    }

    // MARK: - Connect

    /// Connect to the GUI automation socket and complete the handshake.
    ///
    /// If `socketPath` is nil, auto-discovers by scanning the runtime directory.
    /// If `tokenPath` is nil, derives it from the socket path.
    public static func connect(
        socketPath: String? = nil,
        tokenPath: String? = nil
    ) throws -> AppControlClient {
        let resolvedSocketPath: String
        let resolvedTokenPath: String

        if let socketPath {
            resolvedSocketPath = socketPath
            resolvedTokenPath = tokenPath
                ?? GUIAutomationPaths.tokenPath(forSocketPath: socketPath)
                ?? GUIAutomationPaths.tokenPath()
        } else {
            guard let (s, t) = Self.discoverFirstConnectable() else {
                throw AppControlError.guiNotRunning
            }
            resolvedSocketPath = s
            resolvedTokenPath = tokenPath ?? t
        }

        guard let token = GUIAutomationAuth.read(tokenPath: resolvedTokenPath) else {
            throw AppControlError.tokenFileMissing(path: resolvedTokenPath)
        }

        let socket: TYSocket
        do {
            socket = try TYSocket.connect(path: resolvedSocketPath)
        } catch {
            throw AppControlError.guiNotRunning
        }

        let client = AppControlClient(socket: socket)
        try client.performHandshake(token: token)
        return client
    }

    /// Scan the runtime directory and return the first `(socketPath, tokenPath)`
    /// pair whose socket accepts a connection. Close-only probe.
    private static func discoverFirstConnectable() -> (String, String)? {
        for sockPath in GUIAutomationPaths.discoverSocketPaths() {
            guard let probe = try? TYSocket.connect(path: sockPath) else { continue }
            probe.closeSocket()
            guard let tokenPath = GUIAutomationPaths.tokenPath(forSocketPath: sockPath) else {
                continue
            }
            return (sockPath, tokenPath)
        }
        return nil
    }

    // MARK: - Handshake

    private func performHandshake(token: String) throws {
        let request = #"{"cmd":"handshake","token":"\#(escape(token))"}"#
        do {
            try io.writeLine(request)
        } catch {
            throw AppControlError.transport(underlying: error)
        }
        let response = try readResponse()
        switch response {
        case .success:
            isAuthenticated = true
        case .error(let code, let message):
            throw AppControlError.handshakeFailed(reason: "\(code): \(message)")
        }
    }

    // MARK: - Commands

    /// Send `server.ping` and return the server's result string.
    public func ping() throws -> String {
        let response = try sendCommand("server.ping")
        switch response {
        case .success(let value):
            return value ?? ""
        case .error(let code, let message):
            throw AppControlError.serverError(code: code, message: message)
        }
    }

    /// Send a raw command line and parse the single-line JSON response.
    /// Intended for internal use and future commands.
    func sendCommand(_ cmd: String) throws -> Response {
        let line = #"{"cmd":"\#(escape(cmd))"}"#
        do {
            try io.writeLine(line)
        } catch {
            throw AppControlError.transport(underlying: error)
        }
        return try readResponse()
    }

    enum Response {
        case success(String?)
        case error(code: String, message: String)
    }

    private func readResponse() throws -> Response {
        let line: String?
        do {
            line = try io.readLine()
        } catch {
            throw AppControlError.transport(underlying: error)
        }
        guard let line else {
            throw AppControlError.transport(underlying: LineIO.IOError.connectionClosed)
        }
        return try Self.parseResponse(line)
    }

    private static func parseResponse(_ line: String) throws -> Response {
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let ok = obj["ok"] as? Bool else {
            throw AppControlError.invalidResponse(raw: line)
        }
        if ok {
            let resultStr = obj["result"] as? String
            return .success(resultStr)
        } else {
            guard let err = obj["error"] as? [String: Any],
                  let code = err["code"] as? String else {
                throw AppControlError.invalidResponse(raw: line)
            }
            let message = (err["message"] as? String) ?? ""
            return .error(code: code, message: message)
        }
    }

    private func escape(_ s: String) -> String {
        Self.escape(s)
    }

    private static func escape(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data()
        guard let full = String(data: data, encoding: .utf8),
              full.count >= 4 else { return "" }
        // JSONSerialization returns the form `["<escaped>"]`. Strip the
        // array brackets AND the surrounding quotes to get just the
        // inner escaped characters — callers re-add the quotes.
        let inner = full.dropFirst(2).dropLast(2)
        return String(inner)
    }
}

