import Foundation

/// Scans a directory of `<id>.txt` profile files and exposes them as
/// `RawProfile` values. Parsing is delegated to the existing `ConfigParser`;
/// this loader only handles directory discovery, the `extends` keyword, and
/// the built-in `default` fallback.
///
/// Phase 3 adds an in-memory cache for resolved Live fields and a
/// reverse-dependency graph so `invalidate(profileIDs:)` can fan out to every
/// profile that transitively `extends` a changed one. The file watcher
/// itself lives in the app-layer `ConfigLoader` — it drives `reload()` +
/// `invalidate` and listens to `onProfilesChanged`.
public final class ProfileLoader: @unchecked Sendable {

    public static let defaultProfileID = "default"
    public static let profileFileExtension = "txt"

    private let directory: URL
    private let parser: ConfigParser
    private let fileManager: FileManager

    private var rawProfiles: [String: RawProfile] = [:]
    /// Reverse-dependency graph: parent id → set of ids that `extends` it.
    /// Rebuilt on every `reload()`.
    private var dependents: [String: Set<String>] = [:]
    /// Memoised resolved live fields keyed by profile id. Populated lazily
    /// by `resolvedLive(id:)` and cleared by `invalidate`.
    private var liveCache: [String: ResolvedLiveFields] = [:]

    /// Invoked whenever a set of profile ids has been invalidated or had
    /// their cached live fields refreshed. The set includes transitively
    /// affected downstreams. Delivered synchronously on the caller's queue.
    public var onProfilesChanged: ((Set<String>) -> Void)?

    public init(
        directory: URL,
        parser: ConfigParser = ConfigParser(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.parser = parser
        self.fileManager = fileManager
    }

    /// Profile directory being scanned (used by the app-layer file watcher).
    public var directoryURL: URL { directory }

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
        rebuildDependents()
        liveCache.removeAll(keepingCapacity: true)
    }

    /// All currently-loaded raw profiles.
    public var allRawProfiles: [String: RawProfile] {
        rawProfiles
    }

    /// Look up a raw profile by id. Returns `nil` if it does not exist.
    public func rawProfile(id: String) -> RawProfile? {
        rawProfiles[id]
    }

    /// Ids that transitively extend `profileID` (i.e. downstream dependents).
    /// Returns `[profileID]` itself plus every descendant in the graph.
    public func profilesAffectedByChange(to profileID: String) -> Set<String> {
        var result: Set<String> = [profileID]
        var queue: [String] = [profileID]
        while let next = queue.popLast() {
            guard let children = dependents[next] else { continue }
            for child in children where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Drop cached live fields for the given ids (and every downstream that
    /// `extends` them), then fire `onProfilesChanged` with the full set.
    /// The file watcher calls this after `reload()` each time it detects a
    /// change; tests can drive it directly.
    @discardableResult
    public func invalidate(profileIDs: Set<String>) -> Set<String> {
        var affected: Set<String> = []
        for id in profileIDs {
            affected.formUnion(profilesAffectedByChange(to: id))
        }
        for id in affected {
            liveCache.removeValue(forKey: id)
        }
        if !affected.isEmpty {
            onProfilesChanged?(affected)
        }
        return affected
    }

    /// Resolve and cache the Live fields for `profileID`. Missing profile
    /// returns an empty set — callers treat that as "fall back to defaults".
    public func resolvedLive(id profileID: String) -> ResolvedLiveFields {
        if let cached = liveCache[profileID] {
            return cached
        }
        let merger = ProfileMerger(loader: self)
        let live: ResolvedLiveFields
        do {
            live = try merger.resolve(profileID: profileID).live
        } catch {
            live = ResolvedLiveFields()
        }
        liveCache[profileID] = live
        return live
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

    private func rebuildDependents() {
        var graph: [String: Set<String>] = [:]
        for (id, raw) in rawProfiles {
            guard let parent = raw.extendsID else { continue }
            graph[parent, default: []].insert(id)
        }
        dependents = graph
    }
}
