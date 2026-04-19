import Foundation

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
/// Explicitly not handled:
/// - `Include` directives (no chaining)
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
    public static func load(from url: URL = Self.defaultURL) throws -> SSHConfigHosts {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return SSHConfigHosts()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
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
}
