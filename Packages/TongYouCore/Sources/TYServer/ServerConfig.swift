import Foundation

/// Configuration for the tyd server daemon.
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

    public init(
        socketPath: String? = nil,
        autoExitOnNoSessions: Bool = false,
        defaultColumns: UInt16 = 80,
        defaultRows: UInt16 = 24,
        maxScrollback: Int = 10000,
        screenUpdateInterval: TimeInterval = 1.0 / 60.0,
        defaultWorkingDirectory: String? = nil
    ) {
        self.socketPath = socketPath ?? Self.defaultSocketPath()
        self.autoExitOnNoSessions = autoExitOnNoSessions
        self.defaultColumns = defaultColumns
        self.defaultRows = defaultRows
        self.maxScrollback = maxScrollback
        self.screenUpdateInterval = screenUpdateInterval
        self.defaultWorkingDirectory = defaultWorkingDirectory
    }

    public static func defaultSocketPath() -> String {
        runtimeDirectory().appending("/tyd.sock")
    }

    public static func defaultPIDPath() -> String {
        runtimeDirectory().appending("/tyd.pid")
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
