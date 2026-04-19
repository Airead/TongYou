import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A single rule in a TongYou SSH rules file.
///
/// Each rule maps one or more hostname globs to a template profile id.
/// First-match-wins; ordering in the source file is authoritative.
public struct SSHRule: Sendable, Equatable {
    /// Template profile id (e.g. `"ssh-prod"`).
    public let template: String
    /// Lowercased glob patterns. Matching uses POSIX `fnmatch(3)` semantics
    /// (`*`, `?`, `[abc]` character classes).
    public let globs: [String]
    /// 1-based line number in the source file. Used for warnings.
    public let lineNumber: Int

    public init(template: String, globs: [String], lineNumber: Int) {
        self.template = template
        self.globs = globs
        self.lineNumber = lineNumber
    }
}

/// Matches hostnames against a TongYou SSH rules file and returns the
/// template profile id to use for each.
///
/// File format (`~/.config/tongyou/ssh-rules.txt`):
/// ```
/// # Format: <template>  <glob> [<glob> ...]
/// # Blanks and `#` comments are ignored. First matching rule wins.
/// ssh-prod   *.prod.example.com   *-prod-*
/// ssh-dev    *.dev.example.com    *.staging.*
/// ```
///
/// Hostnames are matched case-insensitively (patterns are lowercased at
/// parse time; the hostname is lowercased at match time). No rule match
/// returns `nil`; callers decide the fallback template.
public struct SSHRuleMatcher: Sendable, Equatable {
    public let rules: [SSHRule]
    /// Non-fatal issues encountered while parsing (malformed lines, etc.).
    /// Parsing never throws — a single bad line does not invalidate the
    /// whole file.
    public let warnings: [String]

    public init(rules: [SSHRule] = [], warnings: [String] = []) {
        self.rules = rules
        self.warnings = warnings
    }

    /// Return the template id of the first rule whose globs match
    /// `hostname`, or `nil` if no rule matches.
    public func match(hostname: String) -> String? {
        let h = hostname.lowercased()
        for rule in rules {
            for glob in rule.globs {
                if Self.fnmatch(pattern: glob, string: h) {
                    return rule.template
                }
            }
        }
        return nil
    }

    /// Parse rules from a string. Always succeeds — malformed lines are
    /// skipped and surfaced via `warnings`.
    public static func parse(_ text: String) -> SSHRuleMatcher {
        var rules: [SSHRule] = []
        var warnings: [String] = []

        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = String(rawLine)
            if let hashIdx = line.firstIndex(of: "#") {
                line = String(line[..<hashIdx])
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let tokens = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }

            guard tokens.count >= 2 else {
                warnings.append(
                    "ssh-rules.txt line \(lineNumber): expected '<template> <glob> [...]', got '\(trimmed)'"
                )
                continue
            }
            let template = tokens[0]
            if template.isEmpty {
                warnings.append(
                    "ssh-rules.txt line \(lineNumber): empty template name"
                )
                continue
            }

            let globs = tokens.dropFirst().map { $0.lowercased() }
            rules.append(SSHRule(
                template: template,
                globs: globs,
                lineNumber: lineNumber
            ))
        }

        return SSHRuleMatcher(rules: rules, warnings: warnings)
    }

    /// Load rules from a file at `url`. A missing file yields an empty
    /// matcher (no error). Other I/O / encoding failures are rethrown so
    /// the caller can log them and still start with an empty matcher.
    public static func load(from url: URL) throws -> SSHRuleMatcher {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return SSHRuleMatcher()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    // MARK: - Private

    /// POSIX fnmatch wrapper. Both `pattern` and `string` are expected to
    /// already be lowercased so the match is case-insensitive without
    /// relying on the non-POSIX `FNM_CASEFOLD` extension.
    private static func fnmatch(pattern: String, string: String) -> Bool {
        pattern.withCString { patCStr in
            string.withCString { strCStr in
                Darwin.fnmatch(patCStr, strCStr, 0) == 0
            }
        }
    }
}
