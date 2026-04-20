import Foundation

/// Dual-backend logging for tongyou server.
///
/// - Foreground mode: writes to stderr (visible in terminal).
/// - Daemon mode: writes to `~/.local/share/TongYou/logs/daemon-YYYY-MM-DD.log`.
///
/// Call `Log.configure(daemonize:minLevel:)` once at startup before any logging.
/// In daemon mode, the file level/category filter may be refined at runtime
/// (typically after config load) via `Log.updateFileLogging(level:categories:)`.
public enum Log {

    public enum Category: String, Sendable {
        case server
        case session
        case client
        /// Temporary: investigating remote-mode split-pane cursor misalignment.
        /// Remove along with its call sites once the bug is fixed.
        case cursorTrace
    }

    public enum Level: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        var label: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .warning: return "WARN"
            case .error:   return "ERROR"
            }
        }

        /// Parse from config string. Returns nil for unrecognized values.
        /// Caller interprets "off" separately (disables logging entirely).
        public init?(configValue: String) {
            switch configValue.lowercased() {
            case "debug":           self = .debug
            case "info":            self = .info
            case "warning", "warn": self = .warning
            case "error":           self = .error
            default: return nil
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - State

    /// True once `configure(daemonize: true, ...)` has been called. Foreground
    /// mode ignores `updateFileLogging` to avoid accidentally opening a file
    /// when no one asked for it.
    nonisolated(unsafe) private static var daemonMode = false

    nonisolated(unsafe) private static var writeToStderr = true
    nonisolated(unsafe) private static var writeToFile = false

    nonisolated(unsafe) private static var minLevel: Level = .info
    nonisolated(unsafe) private static var enabledCategories: Set<Category>?

    /// Serial queue for file I/O. Matches the GUILog design so neither logger
    /// blocks the caller's thread.
    private static let fileQueue = DispatchQueue(
        label: "io.github.airead.tongyou.log.file",
        qos: .utility
    )

    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var currentDateString: String?

    /// Override for the log directory. When set, the daemon log writes here
    /// instead of the default `~/.local/share/TongYou/logs`. Intended for tests.
    nonisolated(unsafe) public static var logDirectoryOverride: URL?

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // MARK: - Public API

    /// Boot-time configuration. Call once at startup before any logging.
    /// - Parameters:
    ///   - daemonize: `true` to write to the daemon log file, `false` for stderr.
    ///   - minLevel: Minimum level to emit. Messages below this are skipped.
    public static func configure(daemonize: Bool, minLevel: Level = .info) {
        self.daemonMode = daemonize
        self.minLevel = minLevel
        self.enabledCategories = nil
        self.writeToStderr = !daemonize
        self.writeToFile = daemonize
        if daemonize {
            fileQueue.async {
                openLogFileIfNeeded()
            }
        }
    }

    /// Refine the daemon file logger after configuration is loaded.
    /// - Parameters:
    ///   - level: New minimum level. Pass `nil` to disable file logging entirely.
    ///   - categories: Whitelist of categories. `nil` means all categories.
    ///
    /// No-op in foreground mode — we never open a file there.
    public static func updateFileLogging(level: Level?, categories: Set<Category>?) {
        guard daemonMode else { return }
        if let level {
            minLevel = level
            enabledCategories = categories
            if !writeToFile {
                writeToFile = true
                fileQueue.async { openLogFileIfNeeded() }
            }
        } else {
            writeToFile = false
            fileQueue.async { closeLogFile() }
        }
    }

    /// Block until all pending file writes are flushed. For tests only.
    public static func flush() {
        fileQueue.sync {}
    }

    public static func debug(_ message: @autoclosure () -> String, category: Category = .server) {
        guard shouldEmit(level: .debug, category: category) else { return }
        emit(level: .debug, category: category, message: message())
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .server) {
        guard shouldEmit(level: .info, category: category) else { return }
        emit(level: .info, category: category, message: message())
    }

    public static func warning(_ message: @autoclosure () -> String, category: Category = .server) {
        guard shouldEmit(level: .warning, category: category) else { return }
        emit(level: .warning, category: category, message: message())
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .server) {
        guard shouldEmit(level: .error, category: category) else { return }
        emit(level: .error, category: category, message: message())
    }

    // MARK: - Private

    private static func shouldEmit(level: Level, category: Category) -> Bool {
        if level < minLevel { return false }
        if let cats = enabledCategories, !cats.contains(category) { return false }
        return true
    }

    private static func emit(level: Level, category: Category, message: String) {
        if writeToStderr {
            fputs("[tongyou] [\(level.label)] [\(category.rawValue)] \(message)\n", stderr)
        }
        guard writeToFile else { return }
        let now = Date()
        let timestamp = timestampFormatter.string(from: now)
        let line = "[\(timestamp)] [\(level.label)] [\(category.rawValue)] \(message)\n"
        fileQueue.async {
            rollDateIfNeeded(now)
            if fileHandle == nil {
                openLogFileIfNeeded()
            }
            guard let handle = fileHandle else { return }
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    // MARK: - File Management (all called on fileQueue)

    private static func logDirectory() -> URL {
        if let override = logDirectoryOverride {
            return override
        }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/TongYou/logs")
    }

    private static func logFilePath(for dateString: String) -> URL {
        logDirectory().appendingPathComponent("daemon-\(dateString).log")
    }

    private static func openLogFileIfNeeded() {
        let dateString = dateOnlyFormatter.string(from: Date())
        let dir = logDirectory()
        let filePath = logFilePath(for: dateString)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: filePath)
            handle.seekToEndOfFile()
            fileHandle = handle
            currentDateString = dateString
        } catch {
            // Logging failure must not crash the daemon.
            fputs("[tongyou] [Log] failed to open daemon log file: \(error)\n", stderr)
        }
    }

    private static func closeLogFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        currentDateString = nil
    }

    private static func rollDateIfNeeded(_ now: Date) {
        let dateString = dateOnlyFormatter.string(from: now)
        if dateString != currentDateString {
            closeLogFile()
            openLogFileIfNeeded()
        }
    }
}
