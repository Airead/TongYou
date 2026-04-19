import Foundation
import Darwin

/// A single host entry harvested from `~/.ssh/config`.
///
/// TongYou only uses these as fuzzy-search candidates in the command
/// palette; the `ssh` binary itself still re-reads `ssh_config` when
/// launched, so we don't try to reproduce its full semantics.
public struct SSHConfigHost: Sendable, Equatable {
    /// The alias as the user typed it (panel display / search key).
    public let alias: String
    /// The `Hostname` directive for this alias, if any. Used by the
    /// template rule matcher when deciding which template to apply.
    public let hostname: String?

    public init(alias: String, hostname: String? = nil) {
        self.alias = alias
        self.hostname = hostname
    }
}

/// Parses the tiny subset of `ssh_config` syntax we care about: top-level
/// `Host` declarations plus their `Hostname` directive (if any).
///
/// `Include` directives are expanded by `load(from:)` before parsing — the
/// pure `parse(_:)` entry point ignores them.
///
/// Explicitly not handled:
/// - Any other keyword (silently ignored)
/// - Quoted tokens, backslash escapes
/// - `Match` blocks — treated as a barrier so a `Hostname` inside one
///   doesn't leak back into the previous `Host` block, but no candidates
///   are produced for them.
public struct SSHConfigHosts: Sendable, Equatable {
    public let hosts: [SSHConfigHost]

    public init(hosts: [SSHConfigHost] = []) {
        self.hosts = hosts
    }

    /// Default location of the user's ssh config.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    /// Load hosts from `url`. Missing file → empty result (no error).
    /// Encoding / other IO failures are rethrown.
    ///
    /// `Include` directives (tilde, relative paths, and glob patterns) are
    /// expanded in place before parsing, matching ssh's behavior of
    /// inlining the included content at the Include line — so an `Include`
    /// inside a `Host` block continues that block.
    public static func load(from url: URL = Self.defaultURL) throws -> SSHConfigHosts {
        var inProgress: Set<String> = []
        let text = try expand(url: url, inProgress: &inProgress)
        return parse(text)
    }

    /// Parse ssh_config text into a flat list of concrete host aliases.
    public static func parse(_ text: String) -> SSHConfigHosts {
        var collected: [SSHConfigHost] = []

        // Current in-progress block. `aliases` is empty when the block is a
        // wildcard-only Host, a Match, or before the first Host line.
        var aliases: [String] = []
        var hostname: String?

        func flush() {
            guard !aliases.isEmpty else { return }
            for alias in aliases {
                collected.append(SSHConfigHost(alias: alias, hostname: hostname))
            }
            aliases = []
            hostname = nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            var line = String(rawLine)
            if let hashIdx = line.firstIndex(of: "#") {
                line = String(line[..<hashIdx])
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let (keyword, rest) = splitKeyword(trimmed)
            if keyword.isEmpty { continue }

            switch keyword.lowercased() {
            case "host":
                flush()
                let tokens = rest
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                if tokens.isEmpty || tokens.contains(where: hasWildcard) {
                    // Wildcard-only / mixed line: treat as a rule block, no
                    // concrete candidates.
                    aliases = []
                } else {
                    aliases = tokens
                }
                hostname = nil

            case "match":
                // Open a new block with no candidates so a following
                // `Hostname` doesn't leak into the previous Host block.
                flush()
                aliases = []
                hostname = nil

            case "hostname":
                // First Hostname in a block wins, matching ssh_config.
                if hostname == nil {
                    let val = rest.trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty {
                        hostname = val
                    }
                }

            default:
                // Any other keyword (Port, User, IdentityFile, Include, …)
                // is silently ignored — we only surface aliases + hostname.
                break
            }
        }
        flush()

        return SSHConfigHosts(hosts: collected)
    }

    // MARK: - Helpers

    /// Split a non-empty line into `(keyword, rest)`. The separator is a
    /// run of whitespace and/or an `=` character, matching ssh_config.
    private static func splitKeyword(_ line: String) -> (String, String) {
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch.isWhitespace || ch == "=" { break }
            idx = line.index(after: idx)
        }
        if idx == line.endIndex {
            return (String(line), "")
        }
        let keyword = String(line[line.startIndex..<idx])
        var rest = line[idx...]
        rest = rest.drop(while: { $0.isWhitespace })
        if rest.first == "=" {
            rest = rest.dropFirst()
            rest = rest.drop(while: { $0.isWhitespace })
        }
        return (keyword, String(rest))
    }

    private static func hasWildcard(_ s: String) -> Bool {
        s.contains("*") || s.contains("?")
    }

    // MARK: - Include expansion

    /// Read `url` and inline-expand any `Include` directives so the result
    /// can be fed to `parse(_:)` as a single contiguous document. Matches
    /// ssh's "insert in place" semantics: an Include inside a Host/Match
    /// block continues that block.
    ///
    /// - `inProgress` tracks the canonical paths currently being expanded
    ///   along this recursion branch. A cycle short-circuits to an empty
    ///   string rather than raising. Paths are removed on unwind so the
    ///   same file can legitimately appear in sibling Includes.
    /// - Missing files resolve to empty strings (ssh-equivalent behavior).
    /// - Relative include paths resolve against the directory of the file
    ///   that contains the `Include`. ssh's rule for the top-level user
    ///   config is "relative to `~/.ssh`", which falls out automatically
    ///   when that file lives in `~/.ssh/config`.
    private static func expand(url: URL, inProgress: inout Set<String>) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return ""
        }
        let canonical = url.resolvingSymlinksInPath().standardized.path
        if inProgress.contains(canonical) {
            return ""
        }
        inProgress.insert(canonical)
        defer { inProgress.remove(canonical) }

        let text = try String(contentsOf: url, encoding: .utf8)
        let baseDir = url.deletingLastPathComponent()

        var output = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var stripped = String(rawLine)
            if let hashIdx = stripped.firstIndex(of: "#") {
                stripped = String(stripped[..<hashIdx])
            }
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let (keyword, rest) = splitKeyword(trimmed)
                if keyword.lowercased() == "include", !rest.isEmpty {
                    for token in rest.split(whereSeparator: { $0.isWhitespace }) {
                        for match in resolveIncludePaths(String(token), base: baseDir) {
                            let included = try expand(url: match, inProgress: &inProgress)
                            output.append(included)
                            if !included.isEmpty, !included.hasSuffix("\n") {
                                output.append("\n")
                            }
                        }
                    }
                    continue
                }
            }
            output.append(String(rawLine))
            output.append("\n")
        }
        return output
    }

    /// Resolve a single `Include` token into existing file URLs. Handles
    /// tilde expansion, relative-to-base resolution, and shell-style globs
    /// (`*`, `?`, `[...]`). A token without wildcards returns a single URL
    /// regardless of whether the file exists — the caller tolerates
    /// missing files.
    private static func resolveIncludePaths(_ token: String, base: URL) -> [URL] {
        var path = (token as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = base.appendingPathComponent(path).path
        }
        if containsGlobMetacharacter(path) {
            return runGlob(path).map(URL.init(fileURLWithPath:))
        }
        return [URL(fileURLWithPath: path)]
    }

    private static func containsGlobMetacharacter(_ s: String) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }

    private static func runGlob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        let rc = pattern.withCString { glob($0, 0, nil, &g) }
        guard rc == 0 else { return [] }
        var paths: [String] = []
        let count = Int(g.gl_pathc)
        for i in 0..<count {
            if let cStr = g.gl_pathv[i] {
                paths.append(String(cString: cStr))
            }
        }
        return paths
    }
}
