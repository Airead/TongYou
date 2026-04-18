import Foundation

/// Result of extracting shared `--profile` / `--set` flags from a command's
/// argv slice. `remaining` preserves the original order of every argument
/// that was not consumed, so downstream parsers can keep doing their own
/// single-pass scan on it.
public struct ParsedProfileAndSet: Equatable {
    public let profile: String?
    public let overrides: [String]
    public let remaining: [String]

    public init(profile: String?, overrides: [String], remaining: [String]) {
        self.profile = profile
        self.overrides = overrides
        self.remaining = remaining
    }
}

/// Errors thrown by `extractProfileAndSet` when CLI flags are malformed.
/// Callers typically translate these into a stderr message + `exit(1)`.
public enum ArgParseError: Error, Equatable {
    case profileFlagMissingValue
    case setFlagMissingValue
    case setFlagMissingEquals(String)
}

/// Scan `args` for `--profile <name>` and repeated `--set key=value` pairs,
/// producing JSON-RPC ready pieces for the `pane-profile` Phase 5 plumbing.
///
/// Behavior:
/// - `--profile NAME`: captured as-is; last value wins if repeated.
/// - `--set KEY=VALUE`: split **only** on the first `=` so a value may contain
///   further `=` (e.g. `env=KEY=VALUE`). Reformatted as `"KEY = VALUE"` and
///   appended to the `overrides` list in the order seen. An empty RHS
///   (`--set env=`) is preserved for profile "explicit clear" semantics.
/// - Everything else lands in `remaining` unchanged.
///
/// CLI side performs **no type inference** — values are forwarded as plain
/// strings; the server's field registry decides semantics.
public func extractProfileAndSet(_ args: [String]) throws -> ParsedProfileAndSet {
    var profile: String? = nil
    var overrides: [String] = []
    var remaining: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--profile":
            guard i + 1 < args.count else {
                throw ArgParseError.profileFlagMissingValue
            }
            profile = args[i + 1]
            i += 2
        case "--set":
            guard i + 1 < args.count else {
                throw ArgParseError.setFlagMissingValue
            }
            let value = args[i + 1]
            guard let eqIdx = value.firstIndex(of: "=") else {
                throw ArgParseError.setFlagMissingEquals(value)
            }
            let key = String(value[..<eqIdx])
            let rhs = String(value[value.index(after: eqIdx)...])
            overrides.append("\(key) = \(rhs)")
            i += 2
        default:
            remaining.append(arg)
            i += 1
        }
    }
    return ParsedProfileAndSet(profile: profile, overrides: overrides, remaining: remaining)
}
