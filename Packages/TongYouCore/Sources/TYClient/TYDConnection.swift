import Foundation
import TYProtocol
import TYTerminal

/// Client-side connection to a tongyou server.
///
/// Manages socket communication, message dispatch, and the read loop.
/// The server-side counterpart is `TYServer.TYDConnection` (different type,
/// same name is coincidental — that one represents a client *on the server*).
public final class TYDConnection: @unchecked Sendable {

    private let socket: TYSocket
    nonisolated(unsafe) private var disconnected = false
    private let disconnectLock = NSLock()

    private let readQueue = DispatchQueue(
        label: "io.github.airead.tongyou.client.conn.read",
        qos: .userInteractive
    )
    private let writeQueue = DispatchQueue(
        label: "io.github.airead.tongyou.client.conn.write",
        qos: .userInteractive
    )

    /// Called on readQueue when a server message arrives.
    public var onMessage: (@Sendable (ServerMessage) -> Void)?

    /// Called once when the connection drops.
    public var onDisconnect: (@Sendable () -> Void)?

    public init(socket: TYSocket) {
        self.socket = socket
    }

    // MARK: - Lifecycle

    /// Start receiving messages from the server (non-blocking).
    public func startReadLoop() {
        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Close the underlying socket.
    public func close() {
        socket.closeSocket()
    }

    // MARK: - Send

    /// Send a client message to the server. Thread-safe.
    public func send(_ message: ClientMessage) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.socket.send(message)
            } catch {
                self.handleDisconnect()
            }
        }
    }

    /// Send a client message synchronously (blocks until sent).
    /// Used by CLI tools that need request-response semantics.
    public func sendSync(_ message: ClientMessage) throws {
        try socket.send(message)
    }

    /// Receive a single server message synchronously (blocks until received).
    public func receiveSync() throws -> ServerMessage {
        try socket.receiveServerMessage()
    }

    // MARK: - Handshake

    /// Perform the authentication handshake synchronously.
    /// Sends the token and waits for the server's handshakeResult.
    /// Throws on failure or if the server rejects the token.
    public func performHandshake(token: String) throws {
        try sendSync(ClientMessage.handshake(token: token))
        let response = try receiveSync()
        guard case .handshakeResult(let success) = response, success else {
            throw TYDConnectionError.handshakeFailed
        }
    }

    // MARK: - Private

    private func readLoop() {
        while true {
            do {
                let message = try socket.receiveServerMessage()
                onMessage?(message)
            } catch {
                handleDisconnect()
                return
            }
        }
    }

    private func handleDisconnect() {
        disconnectLock.lock()
        let alreadyDisconnected = disconnected
        disconnected = true
        disconnectLock.unlock()
        guard !alreadyDisconnected else { return }
        onDisconnect?()
    }
}
