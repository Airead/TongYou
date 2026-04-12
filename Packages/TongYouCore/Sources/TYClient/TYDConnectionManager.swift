import Foundation
import TYProtocol
import TYServer

/// Manages the lifecycle of a connection to a tyd server instance.
///
/// Handles auto-starting tyd if not running, establishing the socket connection,
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

    /// Connect to the tyd server. Auto-starts tyd if configured and not running.
    public func connect() throws -> TYDConnection {
        if autoStart {
            try ensureTYDRunning()
        }

        let socket = try TYSocket.connect(path: socketPath)
        let conn = TYDConnection(socket: socket)

        conn.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }

        lock.lock()
        connection = conn
        lock.unlock()

        conn.startReadLoop()
        onConnected?(conn)
        return conn
    }

    /// Disconnect from tyd without stopping the server.
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

    /// Ensure tyd is running, starting it if necessary.
    private func ensureTYDRunning() throws {
        if DaemonLifecycle.checkExistingProcess() != nil {
            return
        }

        let tydPath = try Self.findTYD()
        try startTYD(at: tydPath)

        // Wait for socket to become available (tyd needs time to start).
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                // Give tyd a moment to start listening after creating the socket file.
                Thread.sleep(forTimeInterval: 0.1)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw TYDConnectionError.startTimeout
    }

    /// Find the tyd executable by searching common locations.
    public static func findTYD() throws -> String {
        // Look for tyd in the same directory as the running process.
        let bundle = Bundle.main
        if let tydInBundle = bundle.path(forAuxiliaryExecutable: "tyd") {
            return tydInBundle
        }

        // Look for tyd next to the current executable.
        let execURL = bundle.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let siblingURL = execURL.deletingLastPathComponent().appendingPathComponent("tyd")
        if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
            return siblingURL.path
        }

        // Check common install locations.
        let commonPaths = [
            "/usr/local/bin/tyd",
            "/opt/homebrew/bin/tyd",
            "\(NSHomeDirectory())/.local/bin/tyd",
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw TYDConnectionError.tydNotFound
    }

    private func startTYD(at path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--daemon"]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
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
