import Foundation
import TYProtocol
import TYServer

/// Manages the lifecycle of a connection to a tongyou server instance.
///
/// Handles auto-starting the server if not running, establishing the socket connection,
/// and reconnection on disconnect.
public final class TYDConnectionManager: @unchecked Sendable {

    private var connection: TYDConnection?
    private let socketPath: String
    private let autoStart: Bool
    private let lock = NSLock()

    /// Called when the connection is established and ready.
    public var onConnected: (@Sendable (TYDConnection) -> Void)?

    /// Called when the connection is lost.
    public var onDisconnected: (@Sendable () -> Void)?

    /// Called when an error occurs during connect or auto-start.
    public var onError: (@Sendable (TYDConnectionError) -> Void)?

    public init(socketPath: String? = nil, autoStart: Bool = true) {
        self.socketPath = socketPath ?? ServerConfig.defaultSocketPath()
        self.autoStart = autoStart
    }

    // MARK: - Connect

    /// Connect to the tongyou server. Auto-starts it if configured and not running.
    public func connect() throws -> TYDConnection {
        print("[TYDClient] connect() called, autoStart=\(autoStart), socketPath=\(socketPath)")
        if autoStart {
            try ensureServerRunning()
        }

        print("[TYDClient] Connecting to socket at \(socketPath)")
        let socket = try TYSocket.connect(path: socketPath)
        print("[TYDClient] Socket connected successfully")
        let conn = TYDConnection(socket: socket)

        conn.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }

        lock.lock()
        connection = conn
        lock.unlock()

        conn.startReadLoop()
        onConnected?(conn)
        print("[TYDClient] Connection established and read loop started")
        return conn
    }

    /// Disconnect from the server without stopping it.
    public func disconnect() {
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.close()
    }

    /// Whether we currently have an active connection.
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil
    }

    /// The current connection, if any.
    public var currentConnection: TYDConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    // MARK: - Auto-Start

    /// Ensure the server is running, starting it if necessary.
    private func ensureServerRunning() throws {
        let existingPID = DaemonLifecycle.checkExistingProcess()
        print("[TYDClient] checkExistingProcess() = \(String(describing: existingPID))")
        if existingPID != nil {
            print("[TYDClient] Server already running, skipping start")
            return
        }

        // Remove stale socket file from a previous run before starting.
        print("[TYDClient] Removing stale socket file at \(socketPath)")
        try? FileManager.default.removeItem(atPath: socketPath)

        let execPath = try Self.findTongYou()
        print("[TYDClient] Found tongyou executable at: \(execPath)")
        try startServer(at: execPath)
        print("[TYDClient] startServer() returned, waiting for daemon to be ready...")

        // Wait for both PID file (daemon is alive) and socket file (daemon is listening).
        let deadline = Date().addingTimeInterval(5.0)
        var pollCount = 0
        while Date() < deadline {
            let pidExists = DaemonLifecycle.checkExistingProcess() != nil
            let socketExists = FileManager.default.fileExists(atPath: socketPath)
            pollCount += 1
            if pollCount <= 5 || pollCount % 10 == 0 {
                print("[TYDClient] Poll #\(pollCount): pid=\(pidExists), socket=\(socketExists)")
            }
            if pidExists && socketExists {
                print("[TYDClient] Daemon ready after \(pollCount) polls, proceeding to connect")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        print("[TYDClient] Timeout waiting for daemon after \(pollCount) polls")
        throw TYDConnectionError.startTimeout
    }

    /// Find the tongyou CLI executable bundled in Contents/Resources/app/bin/.
    public static func findTongYou() throws -> String {
        let bundle = Bundle.main
        guard let resourceURL = bundle.resourceURL else {
            print("[TYDClient] findTongYou: bundle.resourceURL is nil")
            throw TYDConnectionError.tydNotFound
        }

        let path = resourceURL.appendingPathComponent("app/bin/tongyou").path
        print("[TYDClient] findTongYou: checking \(path)")
        guard FileManager.default.isExecutableFile(atPath: path) else {
            print("[TYDClient] findTongYou: not found or not executable")
            throw TYDConnectionError.tydNotFound
        }

        print("[TYDClient] findTongYou: found at \(path)")
        return path
    }

    private func startServer(at path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["daemon"]
        process.standardOutput = nil
        process.standardError = nil
        print("[TYDClient] Launching: \(path) daemon")
        try process.run()
        print("[TYDClient] Process launched, pid=\(process.processIdentifier)")
    }

    // MARK: - Private

    private func handleDisconnect() {
        lock.lock()
        connection = nil
        lock.unlock()
        onDisconnected?()
    }
}

/// Errors from TYDConnectionManager.
public enum TYDConnectionError: Error, Sendable {
    case tydNotFound
    case startTimeout
    case notConnected
}
