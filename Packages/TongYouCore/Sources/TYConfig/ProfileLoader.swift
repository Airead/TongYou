import Foundation

/// Scans a directory of `<id>.txt` profile files and exposes them as
/// `RawProfile` values. Parsing is delegated to the existing `ConfigParser`;
/// this loader only handles directory discovery, the `extends` keyword, and
/// the built-in `default` fallback.
///
/// Phase 1 is pure I/O on demand — no file watching. Hot reload arrives in
/// Phase 3 when the loader gains a `DispatchSource`-based watcher.
public final class ProfileLoader: @unchecked Sendable {

    public static let defaultProfileID = "default"
    public static let profileFileExtension = "txt"

    private let directory: URL
    private let parser: ConfigParser
    private let fileManager: FileManager

    private var rawProfiles: [String: RawProfile] = [:]

    public init(
        directory: URL,
        parser: ConfigParser = ConfigParser(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.parser = parser
        self.fileManager = fileManager
    }

    /// Scan the profile directory and (re)populate the in-memory cache.
    /// Missing directory is tolerated — the built-in `default` profile is
    /// still exposed.
    public func reload() throws {
        var loaded: [String: RawProfile] = [:]

        if fileManager.fileExists(atPath: directory.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for url in contents where url.pathExtension == Self.profileFileExtension {
                let id = url.deletingPathExtension().lastPathComponent
                guard !id.isEmpty else { continue }
                let raw = try parseProfile(id: id, at: url)
                loaded[id] = raw
            }
        }

        // Ensure built-in `default` is always resolvable. If the user wrote a
        // `default.txt`, that one takes precedence.
        if loaded[Self.defaultProfileID] == nil {
            loaded[Self.defaultProfileID] = RawProfile(
                id: Self.defaultProfileID,
                extendsID: nil,
                entries: []
            )
        }

        rawProfiles = loaded
    }

    /// All currently-loaded raw profiles.
    public var allRawProfiles: [String: RawProfile] {
        rawProfiles
    }

    /// Look up a raw profile by id. Returns `nil` if it does not exist.
    public func rawProfile(id: String) -> RawProfile? {
        rawProfiles[id]
    }

    // MARK: - Private

    private func parseProfile(id: String, at url: URL) throws -> RawProfile {
        let parsed = try parser.parse(contentsOf: url)

        var extendsID: String?
        var entries: [ConfigParser.Entry] = []
        entries.reserveCapacity(parsed.count)

        for entry in parsed {
            if entry.key == FieldRegistry.extendsKey {
                // Last `extends` wins. Empty value means "no parent" and clears
                // any previously-set extends from the same file.
                extendsID = entry.value.isEmpty ? nil : entry.value
                continue
            }
            entries.append(entry)
        }

        return RawProfile(id: id, extendsID: extendsID, entries: entries)
    }
}
