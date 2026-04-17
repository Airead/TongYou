import Foundation

/// Errors that can occur during configuration file parsing.
public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case fileNotReadable(path: String, underlying: any Error)
    case circularInclude(path: String)
    case maxIncludeDepthExceeded(path: String)
    case invalidValue(key: String, value: String)

    public var description: String {
        switch self {
        case .fileNotReadable(let path, let err):
            return "Cannot read config file '\(path)': \(err.localizedDescription)"
        case .circularInclude(let path):
            return "Circular config-file include detected: '\(path)'"
        case .maxIncludeDepthExceeded(let path):
            return "Config include depth exceeded at '\(path)'"
        case .invalidValue(let key, let value):
            return "Invalid value '\(value)' for config key '\(key)'"
        }
    }
}
