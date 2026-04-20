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

    public typealias Level = LogLevel

    // MARK: - State

    nonisolated(unsafe) private static var writeToStderr = true
    nonisolated(unsafe) private static var writeToFile = false

    nonisolated(unsafe) private static var minLevel: Level = .info
    nonisolated(unsafe) private static var enabledCategories: Set<Category>?

    private static let fileWriter = FileLogWriter(
        filePrefix: "daemon",
        queueLabel: "io.github.airead.tongyou.log.file"
    )

    /// Override for the log directory. When set, the daemon log writes here
    /// instead of the default `~/.local/share/TongYou/logs`. Intended for tests.
    public nonisolated(unsafe) static var logDirectoryOverride: URL? {
        get { fileWriter.logDirectoryOverride }
        set { fileWriter.logDirectoryOverride = newValue }
    }

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // MARK: - Public API

    /// Boot-time configuration. Call once at startup before any logging.
    ///
    /// Both foreground and daemon modes write to the log file; stderr is
    /// additionally enabled in foreground so operators see live output in
    /// their terminal. The file may be disabled afterwards via
    /// `updateFileLogging(level: nil, ...)` once config is loaded.
    ///
    /// - Parameters:
    ///   - daemonize: `true` to suppress stderr (daemonized process has no
    ///     usable stderr anyway); `false` to keep stderr active.
    ///   - minLevel: Minimum level to emit. Messages below this are skipped.
    public static func configure(daemonize: Bool, minLevel: Level = .info) {
        self.minLevel = minLevel
        self.enabledCategories = nil
        self.writeToStderr = !daemonize
        self.writeToFile = true
        fileWriter.openFile()
    }

    /// Refine the file logger after config is loaded. Applies in both
    /// foreground and daemon modes.
    /// - Parameters:
    ///   - level: New minimum level. Pass `nil` to disable file logging
    ///     entirely (stderr, if active, keeps flowing under the prior level).
    ///   - categories: Whitelist of categories. `nil` means all categories.
    public static func updateFileLogging(level: Level?, categories: Set<Category>?) {
        if let level {
            minLevel = level
            enabledCategories = categories
            if !writeToFile {
                writeToFile = true
                fileWriter.openFile()
            }
        } else {
            writeToFile = false
            fileWriter.closeFile()
        }
    }

    /// Block until all pending file writes are flushed. For tests only.
    public static func flush() {
        fileWriter.flush()
    }

    /// Atomically restore default state (no file, stderr on, info level, no
    /// category filter, no override). Drains the file queue so no deferred
    /// opens can race with the override being cleared. Tests only.
    public static func resetForTesting() {
        writeToFile = false
        fileWriter.closeFile()
        writeToStderr = true
        minLevel = .info
        enabledCategories = nil
        logDirectoryOverride = nil
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
        fileWriter.writeLine(line, date: now)
    }
}
