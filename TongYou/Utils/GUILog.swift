import Foundation
import TYServer

/// File-based logging for the TongYou GUI client.
///
/// - Disabled by default; enable via `debug-log-level` in the config file.
/// - When disabled, each call is a single boolean check — no string formatting,
///   no I/O, no allocation.
/// - When enabled, writes to `~/.local/share/TongYou/logs/gui-YYYY-MM-DD.log`.
/// - Thread-safe: all file I/O is serialized on a dedicated dispatch queue.
enum GUILog {

    enum Category: String, CaseIterable, Sendable {
        case renderer
        case session
        case config
        case input
        case general
        /// Temporary: investigating remote-mode split-pane cursor misalignment.
        /// Remove along with its call sites once the bug is fixed.
        case cursorTrace
    }

    typealias Level = LogLevel

    // MARK: - State

    nonisolated(unsafe) private static var _enabled = false

    /// Minimum level to emit. Messages below this level are discarded.
    nonisolated(unsafe) private static var _minimumLevel: Level = .debug

    /// When non-nil, only these categories are logged. Nil means all categories.
    nonisolated(unsafe) private static var _enabledCategories: Set<Category>?

    private static let fileWriter = FileLogWriter(
        filePrefix: "gui",
        queueLabel: "io.github.airead.tongyou.guilog"
    )

    /// Override for the log directory. When set, logs write here instead of the
    /// default `~/.local/share/TongYou/logs`. Intended for testing.
    nonisolated(unsafe) static var logDirectoryOverride: URL? {
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

    /// Enable file logging with optional filtering.
    /// - Parameters:
    ///   - level: Minimum log level (default: .debug).
    ///   - categories: Categories to log. Nil means all categories.
    static func enable(level: Level = .debug, categories: Set<Category>? = nil) {
        _minimumLevel = level
        _enabledCategories = categories
        _enabled = true
        fileWriter.openFile()
    }

    /// Disable file logging. Closes the file handle and releases resources.
    static func disable() {
        _enabled = false
        _enabledCategories = nil
        fileWriter.closeFile()
    }

    /// Whether logging is currently enabled.
    static var isEnabled: Bool { _enabled }

    /// Current minimum log level.
    static var minimumLevel: Level { _minimumLevel }

    /// Currently enabled categories. Nil means all.
    static var enabledCategories: Set<Category>? { _enabledCategories }

    /// Block until all pending log writes are flushed. For testing only.
    static func flush() {
        fileWriter.flush()
    }

    static func debug(_ message: @autoclosure () -> String, category: Category = .general) {
        guard _enabled, shouldEmit(level: .debug, category: category) else { return }
        emit(level: .debug, category: category, message: message())
    }

    static func info(_ message: @autoclosure () -> String, category: Category = .general) {
        guard _enabled, shouldEmit(level: .info, category: category) else { return }
        emit(level: .info, category: category, message: message())
    }

    static func warning(_ message: @autoclosure () -> String, category: Category = .general) {
        guard _enabled, shouldEmit(level: .warning, category: category) else { return }
        emit(level: .warning, category: category, message: message())
    }

    static func error(_ message: @autoclosure () -> String, category: Category = .general) {
        guard _enabled, shouldEmit(level: .error, category: category) else { return }
        emit(level: .error, category: category, message: message())
    }

    // MARK: - Private

    /// Check whether a message should be emitted based on level and category filters.
    private static func shouldEmit(level: Level, category: Category) -> Bool {
        if level < _minimumLevel { return false }
        if let cats = _enabledCategories, !cats.contains(category) { return false }
        return true
    }

    private static func emit(level: Level, category: Category, message: String) {
        let now = Date()
        let timestamp = timestampFormatter.string(from: now)
        let line = "[\(timestamp)] [\(level.label)] [\(category.rawValue)] \(message)\n"
        fileWriter.writeLine(line, date: now)
    }
}
