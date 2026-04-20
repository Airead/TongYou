import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "debug":           self = .debug
        case "info":            self = .info
        case "warning", "warn": self = .warning
        case "error":           self = .error
        default: return nil
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
