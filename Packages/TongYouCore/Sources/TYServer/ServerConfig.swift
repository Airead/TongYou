import Foundation

/// Configuration for the tongyou server daemon.
public struct ServerConfig: Sendable, Equatable {
    public var socketPath: String
    public var autoExitOnNoSessions: Bool
    public var defaultColumns: UInt16
    public var defaultRows: UInt16
    public var maxScrollback: Int

    /// Minimum coalesce delay for screen updates (seconds).
    /// After the screen becomes dirty, the server waits at least this long
    /// before flushing, allowing multiple changes to batch into one send.
    /// Default: 1ms — near-instant response for interactive typing.
    public var minCoalesceDelay: TimeInterval

    /// Maximum coalesce delay for screen updates (seconds).
    /// During sustained output (e.g. `cat` of a large file), the delay
    /// ramps up exponentially from minCoalesceDelay to this cap.
    /// Default: 200ms (~5fps) to reduce bandwidth under heavy output.
    public var maxCoalesceDelay: TimeInterval

    /// Default working directory for new shells. nil means use $HOME.
    public var defaultWorkingDirectory: String?

    /// Maximum pending screen update messages per client before dropping.
    /// Screen updates beyond this threshold are discarded since the next
    /// timer tick will send fresh data anyway.
    public var maxPendingScreenUpdates: Int

    /// Interval in seconds between periodic stats logging (0 = disabled).
    public var statsInterval: TimeInterval

    /// Directory where session persistence files are stored.
    /// If nil, sessions are not persisted to disk.
    public var persistenceDirectory: String?

    // MARK: - Default Values

    public static let defaultAutoExitOnNoSessions: Bool = false
    public static let defaultMaxScrollback: Int = 10000
    public static let defaultMinCoalesceDelay: TimeInterval = 0.001
    public static let defaultMaxCoalesceDelay: TimeInterval = 0.200
    public static let defaultMaxPendingScreenUpdates: Int = 3
    public static let defaultStatsInterval: TimeInterval = 30.0

    public init(
        socketPath: String? = nil,
        autoExitOnNoSessions: Bool = defaultAutoExitOnNoSessions,
        defaultColumns: UInt16 = 80,
        defaultRows: UInt16 = 24,
        maxScrollback: Int = defaultMaxScrollback,
        minCoalesceDelay: TimeInterval = defaultMinCoalesceDelay,
        maxCoalesceDelay: TimeInterval = defaultMaxCoalesceDelay,
        defaultWorkingDirectory: String? = nil,
        maxPendingScreenUpdates: Int = defaultMaxPendingScreenUpdates,
        statsInterval: TimeInterval = defaultStatsInterval,
        persistenceDirectory: String? = nil
    ) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
        self.autoExitOnNoSessions = autoExitOnNoSessions
        self.defaultColumns = defaultColumns
        self.defaultRows = defaultRows
        self.maxScrollback = maxScrollback
        self.minCoalesceDelay = minCoalesceDelay
        self.maxCoalesceDelay = maxCoalesceDelay
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.maxPendingScreenUpdates = maxPendingScreenUpdates
        self.statsInterval = statsInterval
        self.persistenceDirectory = persistenceDirectory
    }

    public static func defaultSocketPath() -> String {
        runtimeDirectory().appending("/tongyou.sock")
    }

    public static func defaultPIDPath() -> String {
        runtimeDirectory().appending("/tongyou.pid")
    }

    public static func defaultTokenPath() -> String {
        runtimeDirectory().appending("/auth-token")
    }

    public static func defaultPersistenceDirectory() -> String {
        persistenceDirectory(subpath: "remote")
    }

    public static func defaultLocalPersistenceDirectory() -> String {
        persistenceDirectory(subpath: "local")
    }

    private static func persistenceDirectory(subpath: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        let base = (home as NSString).appendingPathComponent(".local/share/TongYou/sessions")
        return (base as NSString).appendingPathComponent(subpath)
    }

    /// Ensure the parent directory of the given path exists, creating it if needed.
    /// Sets directory permissions to 0700 (owner-only access).
    static func ensureParentDirectory(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Enforce permissions even if the directory already existed.
        chmod(dir, 0o700)
    }

    private static func runtimeDirectory() -> String {
        let baseDir: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            baseDir = xdg
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
            baseDir = (home as NSString).appendingPathComponent("Library/Caches")
        }
        return (baseDir as NSString).appendingPathComponent("tongyou")
    }
}
