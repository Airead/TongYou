import Foundation

/// A parsed automation reference identifying a session, tab, pane, or float.
///
/// String forms:
///   - `<session>`                 e.g. `dev` or `sess:1`
///   - `<session>/tab:<n>`         e.g. `dev/tab:2`
///   - `<session>/pane:<n>`        e.g. `dev/pane:3`
///   - `<session>/float:<n>`       e.g. `dev/float:1`
///
/// The session segment is either a user-provided name (no `/`, `:`, or whitespace)
/// or an auto-generated `sess:<n>` fallback.
public enum AutomationRef: Sendable, Equatable, Hashable {
    case session(String)
    case tab(session: String, index: UInt)
    case pane(session: String, index: UInt)
    case float(session: String, index: UInt)

    public var sessionSegment: String {
        switch self {
        case .session(let s),
             .tab(let s, _),
             .pane(let s, _),
             .float(let s, _):
            return s
        }
    }

    /// Canonical string representation. Round-trips with `parse(_:)`.
    public var description: String {
        switch self {
        case .session(let s): return s
        case .tab(let s, let n): return "\(s)/tab:\(n)"
        case .pane(let s, let n): return "\(s)/pane:\(n)"
        case .float(let s, let n): return "\(s)/float:\(n)"
        }
    }

    /// Parse a ref string. Throws `AutomationError.invalidRef` on malformed input.
    public static func parse(_ raw: String) throws -> AutomationRef {
        guard !raw.isEmpty else { throw AutomationError.invalidRef(raw) }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            throw AutomationError.invalidRef(raw)
        }

        let sessionSegment = String(parts[0])
        try validateSessionSegment(sessionSegment, original: raw)

        if parts.count == 1 {
            return .session(sessionSegment)
        }

        let sub = String(parts[1])
        let subParts = sub.split(separator: ":", omittingEmptySubsequences: false)
        guard subParts.count == 2 else { throw AutomationError.invalidRef(raw) }
        let kind = String(subParts[0])
        let numberStr = String(subParts[1])
        guard let index = UInt(numberStr), !numberStr.isEmpty else {
            throw AutomationError.invalidRef(raw)
        }

        switch kind {
        case "tab": return .tab(session: sessionSegment, index: index)
        case "pane": return .pane(session: sessionSegment, index: index)
        case "float": return .float(session: sessionSegment, index: index)
        default: throw AutomationError.invalidRef(raw)
        }
    }

    /// Validate that a session segment is either a legal user name or the
    /// `sess:<n>` auto-generated form.
    private static func validateSessionSegment(_ s: String, original: String) throws {
        guard !s.isEmpty else { throw AutomationError.invalidRef(original) }

        // Accept `sess:<n>` form explicitly.
        if let colon = s.firstIndex(of: ":") {
            let prefix = s[..<colon]
            let suffix = s[s.index(after: colon)...]
            if prefix == "sess", let _ = UInt(suffix), !suffix.isEmpty { return }
            // Any other colon in the session segment is illegal.
            throw AutomationError.invalidRef(original)
        }

        // User-name form: reject whitespace.
        if s.contains(where: { $0.isWhitespace }) {
            throw AutomationError.invalidRef(original)
        }
    }

    /// True if the given string could be a user-chosen session name used
    /// directly as a ref (no `/`, no `:`, no whitespace, non-empty, and
    /// not matching an auto-generated pattern like `sess:1`, `tab:2`, etc.).
    public static func canUseAsSessionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains(where: { $0 == "/" || $0 == ":" || $0.isWhitespace }) {
            return false
        }
        return !matchesReservedPattern(name)
    }

    private static let reservedPrefixes: [String] = ["sess", "tab", "pane", "float"]

    /// True if `name` matches `(sess|tab|pane|float):\d+`.
    private static func matchesReservedPattern(_ name: String) -> Bool {
        guard let colon = name.firstIndex(of: ":") else { return false }
        let prefix = String(name[..<colon])
        let suffix = name[name.index(after: colon)...]
        guard reservedPrefixes.contains(prefix) else { return false }
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
