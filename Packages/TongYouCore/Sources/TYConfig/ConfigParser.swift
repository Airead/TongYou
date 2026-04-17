import Foundation

/// Parses Ghostty-style `key = value` configuration files.
///
/// Supported syntax:
/// - Lines starting with `#` are comments (must be on their own line).
/// - Blank lines are ignored.
/// - `key = value` sets a configuration entry; whitespace around `=` is trimmed.
/// - `key =` (empty value) resets to default.
/// - `config-file = path` recursively includes another file (max depth 10, cycle detection).
/// - `?` prefix on config-file path makes it optional (no error if missing).
public struct ConfigParser: Sendable {

    /// A single parsed key-value entry.
    public struct Entry: Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Maximum include depth to prevent runaway recursion.
    private static let maxIncludeDepth = 10

    public init() {}

    /// Parse a configuration file at the given URL.
    /// Returns entries in order, preserving duplicate keys (for list-valued keys like `keybind`).
    public func parse(contentsOf url: URL) throws -> [Entry] {
        try parse(contentsOf: url, visitedPaths: [], depth: 0)
    }

    // MARK: - Private

    private func parse(
        contentsOf url: URL,
        visitedPaths: [String],
        depth: Int
    ) throws -> [Entry] {
        guard depth <= Self.maxIncludeDepth else {
            throw ConfigError.maxIncludeDepthExceeded(path: url.path)
        }

        let canonicalPath = url.standardizedFileURL.path
        if visitedPaths.contains(canonicalPath) {
            throw ConfigError.circularInclude(path: canonicalPath)
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.fileNotReadable(path: url.path, underlying: error)
        }

        var visited = visitedPaths
        visited.append(canonicalPath)

        var entries: [Entry] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Split on first `=`
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                continue  // Malformed line — skip silently
            }

            let key = trimmed[trimmed.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else { continue }

            // Handle config-file includes
            if key == "config-file" {
                let includeEntries = try resolveInclude(
                    value: value,
                    relativeTo: url,
                    visitedPaths: visited,
                    depth: depth + 1
                )
                entries.append(contentsOf: includeEntries)
                continue
            }

            entries.append(Entry(key: key, value: value))
        }

        return entries
    }

    private func resolveInclude(
        value: String,
        relativeTo parentURL: URL,
        visitedPaths: [String],
        depth: Int
    ) throws -> [Entry] {
        var path = value
        let optional = path.hasPrefix("?")
        if optional {
            path = String(path.dropFirst())
        }

        // Strip optional quotes
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }

        guard !path.isEmpty else { return [] }

        // Resolve relative paths against parent file's directory
        let url: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
        } else {
            url = parentURL.deletingLastPathComponent().appendingPathComponent(path)
        }

        do {
            return try parse(contentsOf: url, visitedPaths: visitedPaths, depth: depth)
        } catch {
            if optional { return [] }
            throw error
        }
    }
}
