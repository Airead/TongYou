import Foundation

/// Configuration for the tongyou server daemon.
public struct ServerConfig: Sendable {
    public var socketPath: String
    public var autoExitOnNoSessions: Bool
    public var defaultColumns: UInt16
    public var defaultRows: UInt16
    public var maxScrollback: Int

    /// Screen update interval in seconds (controls diff send rate).
    /// Default: ~60fps (16ms).
    public var screenUpdateInterval: TimeInterval

    /// Default working directory for new shells. nil means use $HOME.
    public var defaultWorkingDirectory: String?

    /// Maximum pending screen update messages per client before dropping.
    /// Screen updates beyond this threshold are discarded since the next
    /// timer tick will send fresh data anyway.
    public var maxPendingScreenUpdates: Int

    /// Interval in seconds between periodic stats logging (0 = disabled).
    public var statsInterval: TimeInterval

    public init(
        socketPath: String? = nil,
        autoExitOnNoSessions: Bool = false,
        defaultColumns: UInt16 = 80,
        defaultRows: UInt16 = 24,
        maxScrollback: Int = 10000,
        screenUpdateInterval: TimeInterval = 1.0 / 60.0,
        defaultWorkingDirectory: String? = nil,
        maxPendingScreenUpdates: Int = 3,
        statsInterval: TimeInterval = 30.0
    ) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
        self.autoExitOnNoSessions = autoExitOnNoSessions
        self.defaultColumns = defaultColumns
        self.defaultRows = defaultRows
        self.maxScrollback = maxScrollback
        self.screenUpdateInterval = screenUpdateInterval
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.maxPendingScreenUpdates = maxPendingScreenUpdates
        self.statsInterval = statsInterval
    }

    public static func defaultSocketPath() -> String {
        runtimeDirectory().appending("/tongyou.sock")
    }

    public static func defaultPIDPath() -> String {
        runtimeDirectory().appending("/tongyou.pid")
    }

    /// Ensure the parent directory of the given path exists, creating it if needed.
    static func ensureParentDirectory(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
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
