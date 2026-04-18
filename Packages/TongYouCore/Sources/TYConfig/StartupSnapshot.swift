import Foundation

/// A single environment variable in a `StartupSnapshot`.
public struct EnvVar: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Strongly-typed, resolved-at-creation startup parameters for a pane.
///
/// Produced from `ResolvedStartupFields` at `SessionManager.createPane` time
/// and attached to `TerminalPane`. The PTY-launching layer (local
/// `TerminalController`, server `createAndStartPane`) reads fields directly;
/// it does not re-resolve the profile.
public struct StartupSnapshot: Sendable, Equatable {
    public var command: String?
    public var args: [String]
    public var cwd: String?
    public var env: [EnvVar]
    /// `nil` or `true` → auto-close pane when the process exits (current
    /// default behavior). `false` → keep the pane open after exit so the
    /// user can read the output; the pane is marked exited and can be
    /// dismissed manually.
    public var closeOnExit: Bool?
    public var initialX: Int?
    public var initialY: Int?
    public var initialWidth: Int?
    public var initialHeight: Int?

    public init(
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        env: [EnvVar] = [],
        closeOnExit: Bool? = nil,
        initialX: Int? = nil,
        initialY: Int? = nil,
        initialWidth: Int? = nil,
        initialHeight: Int? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.closeOnExit = closeOnExit
        self.initialX = initialX
        self.initialY = initialY
        self.initialWidth = initialWidth
        self.initialHeight = initialHeight
    }

    /// Convenience accessor: env as `(key, value)` tuples in insertion order.
    public var envTuples: [(String, String)] {
        env.map { ($0.key, $0.value) }
    }
}

// MARK: - Building from a resolved profile

extension StartupSnapshot {

    /// Build a snapshot from resolved profile startup fields. Any invalid
    /// string values (e.g. non-integer `initial-x`) are dropped and appended
    /// to `warnings`.
    public init(
        from resolved: ResolvedStartupFields,
        warnings: inout [String]
    ) {
        self.command = resolved.command
        self.args = resolved.args
        self.cwd = resolved.cwd
        self.env = resolved.env.map { EnvVar(key: $0.key, value: $0.value) }

        self.closeOnExit = Self.parseBool(
            resolved.closeOnExit,
            fieldName: "close-on-exit",
            warnings: &warnings
        )
        self.initialX = Self.parseInt(
            resolved.initialX,
            fieldName: "initial-x",
            warnings: &warnings
        )
        self.initialY = Self.parseInt(
            resolved.initialY,
            fieldName: "initial-y",
            warnings: &warnings
        )
        self.initialWidth = Self.parseInt(
            resolved.initialWidth,
            fieldName: "initial-width",
            warnings: &warnings
        )
        self.initialHeight = Self.parseInt(
            resolved.initialHeight,
            fieldName: "initial-height",
            warnings: &warnings
        )
    }

    /// Ignore-warnings convenience; useful in tests and hot paths where
    /// the caller doesn't care about per-field reasons.
    public init(from resolved: ResolvedStartupFields) {
        var discarded: [String] = []
        self.init(from: resolved, warnings: &discarded)
    }

    private static func parseBool(
        _ raw: String?,
        fieldName: String,
        warnings: inout [String]
    ) -> Bool? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "true", "yes", "1", "on":
            return true
        case "false", "no", "0", "off":
            return false
        default:
            warnings.append(
                "Invalid boolean for '\(fieldName)': '\(raw)' — expected true/false/yes/no/1/0"
            )
            return nil
        }
    }

    private static func parseInt(
        _ raw: String?,
        fieldName: String,
        warnings: inout [String]
    ) -> Int? {
        guard let raw else { return nil }
        if let value = Int(raw) {
            return value
        }
        warnings.append("Invalid integer for '\(fieldName)': '\(raw)'")
        return nil
    }
}
