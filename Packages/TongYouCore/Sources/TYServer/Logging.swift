import Foundation
import os

/// Dual-backend logging for tyd.
///
/// - Foreground mode: writes to stderr (visible in terminal).
/// - Daemon mode: writes to `os.Logger` (visible via `log stream`).
///
/// Call `Log.configure(useSyslog:)` once at startup before any logging.
public enum Log {

    public enum Category: String, Sendable {
        case server
        case session
        case client
    }

    public enum Level: Int, Sendable {
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
    }

    // MARK: - Configuration

    nonisolated(unsafe) private static var useSyslog = false
    nonisolated(unsafe) private static var minLevel: Level = .info

    private static let subsystem = "io.github.airead.tongyou.tyd"

    // Lazily created os.Logger instances (only used in daemon mode).
    nonisolated(unsafe) private static var loggers: [Category: Logger] = [:]
    private static let loggersLock = NSLock()

    /// Configure the logging backend. Must be called once before any logging.
    /// - Parameters:
    ///   - useSyslog: `true` for daemon mode (os.Logger), `false` for foreground (stderr).
    ///   - minLevel: Minimum level to emit. Messages below this are skipped entirely.
    public static func configure(useSyslog: Bool, minLevel: Level = .info) {
        self.useSyslog = useSyslog
        self.minLevel = minLevel
    }

    // MARK: - Public API

    public static func debug(_ message: @autoclosure () -> String, category: Category = .server) {
        guard minLevel.rawValue <= Level.debug.rawValue else { return }
        emit(level: .debug, category: category, message: message())
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .server) {
        guard minLevel.rawValue <= Level.info.rawValue else { return }
        emit(level: .info, category: category, message: message())
    }

    public static func warning(_ message: @autoclosure () -> String, category: Category = .server) {
        guard minLevel.rawValue <= Level.warning.rawValue else { return }
        emit(level: .warning, category: category, message: message())
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .server) {
        emit(level: .error, category: category, message: message())
    }

    // MARK: - Private

    private static func emit(level: Level, category: Category, message: String) {
        if useSyslog {
            let logger = getOrCreateLogger(for: category)
            switch level {
            case .debug:   logger.debug("\(message, privacy: .public)")
            case .info:    logger.info("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            case .error:   logger.error("\(message, privacy: .public)")
            }
        } else {
            fputs("[tyd] [\(level.label)] [\(category.rawValue)] \(message)\n", stderr)
        }
    }

    private static func getOrCreateLogger(for category: Category) -> Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let existing = loggers[category] {
            return existing
        }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = logger
        return logger
    }
}
