import Foundation

/// Errors raised while resolving a profile.
public enum ProfileResolveError: Error, CustomStringConvertible, Sendable {
    case profileNotFound(id: String)
    case circularExtends(chain: [String])
    case extendsDepthExceeded(chain: [String])
    case invalidOverrideLine(index: Int, line: String)

    public var description: String {
        switch self {
        case .profileNotFound(let id):
            return "Profile not found: '\(id)'"
        case .circularExtends(let chain):
            return "Circular extends chain: \(chain.joined(separator: " -> "))"
        case .extendsDepthExceeded(let chain):
            return "Profile extends depth exceeded: \(chain.joined(separator: " -> "))"
        case .invalidOverrideLine(let index, let line):
            return "Invalid override line at index \(index): '\(line)'"
        }
    }
}

/// Merges a profile's `extends` chain plus call-site overrides into a single
/// `ResolvedProfile`. Stateless across calls — cheap to invoke per pane.
public struct ProfileMerger: Sendable {

    /// Matches `ConfigParser`'s include-depth cap.
    public static let maxExtendsDepth = 10

    private let loader: ProfileLoader

    public init(loader: ProfileLoader) {
        self.loader = loader
    }

    /// Resolve `profileID` against the current raw profiles and the given
    /// call-site overrides (one `key = value` line each, parsed with the same
    /// semantics as a profile file).
    public func resolve(
        profileID: String,
        overrides: [String] = []
    ) throws -> ResolvedProfile {
        let layers = try buildExtendsChain(rootID: profileID)
        let overrideEntries = try parseOverrides(overrides)

        var accumulator = Accumulator()
        var warnings: [String] = []

        for raw in layers {
            accumulator.beginLayer()
            for entry in raw.entries {
                apply(entry: entry, to: &accumulator, warnings: &warnings)
            }
        }

        if !overrideEntries.isEmpty {
            accumulator.beginLayer()
            for entry in overrideEntries {
                apply(entry: entry, to: &accumulator, warnings: &warnings)
            }
        }

        return accumulator.build(profileID: profileID, warnings: warnings)
    }

    // MARK: - Extends chain

    private func buildExtendsChain(rootID: String) throws -> [RawProfile] {
        var chainIDs: [String] = []
        var chain: [RawProfile] = []
        var currentID: String? = rootID

        while let id = currentID {
            if chainIDs.contains(id) {
                throw ProfileResolveError.circularExtends(chain: chainIDs + [id])
            }
            if chain.count >= Self.maxExtendsDepth {
                throw ProfileResolveError.extendsDepthExceeded(chain: chainIDs + [id])
            }
            guard let raw = loader.rawProfile(id: id) else {
                throw ProfileResolveError.profileNotFound(id: id)
            }
            chainIDs.append(id)
            chain.append(raw)
            currentID = raw.extendsID
        }

        // Reverse so the list is root → leaf (lowest → highest priority).
        return chain.reversed()
    }

    // MARK: - Overrides parsing

    private func parseOverrides(_ lines: [String]) throws -> [ConfigParser.Entry] {
        var result: [ConfigParser.Entry] = []
        result.reserveCapacity(lines.count)

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                throw ProfileResolveError.invalidOverrideLine(index: index, line: raw)
            }
            let key = trimmed[trimmed.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                throw ProfileResolveError.invalidOverrideLine(index: index, line: raw)
            }
            if key == FieldRegistry.extendsKey {
                // `extends` is not a valid override — it would redirect the
                // resolution after the chain has already been built.
                throw ProfileResolveError.invalidOverrideLine(index: index, line: raw)
            }
            result.append(ConfigParser.Entry(key: key, value: value))
        }

        return result
    }

    // MARK: - Apply single entry

    private func apply(
        entry: ConfigParser.Entry,
        to acc: inout Accumulator,
        warnings: inout [String]
    ) {
        guard let lookup = FieldRegistry.resolve(entryKey: entry.key) else {
            warnings.append("Unknown profile key ignored: '\(entry.key)'")
            return
        }

        switch lookup.descriptor.kind {
        case .scalar:
            if entry.value.isEmpty {
                acc.clearScalar(lookup.descriptor.canonicalKey)
            } else {
                acc.setScalar(lookup.descriptor.canonicalKey, value: entry.value)
            }

        case .list:
            let key = lookup.descriptor.canonicalKey
            let firstTouchInLayer = !acc.listTouchedInCurrentLayer(key)
            if firstTouchInLayer {
                acc.clearList(key)
                acc.markListTouchedInCurrentLayer(key)
            }
            if entry.value.isEmpty {
                // Explicit clear; also clears anything appended earlier in
                // this layer.
                acc.clearList(key)
            } else {
                acc.appendList(key, value: entry.value)
            }

        case .map:
            let key = lookup.descriptor.canonicalKey
            // Empty value + no sub-key → clear whole map.
            if entry.value.isEmpty && lookup.subKey == nil {
                acc.clearMap(key)
                return
            }

            let resolvedSubKey: String
            let resolvedValue: String

            if let suffix = lookup.subKey {
                // Sub-key came from the entry key suffix (e.g. palette-0).
                resolvedSubKey = suffix
                resolvedValue = entry.value
                if resolvedValue.isEmpty {
                    acc.removeMapEntry(key, subKey: resolvedSubKey)
                    return
                }
            } else {
                // Sub-key must come from the value (e.g. env = FOO=bar).
                guard case .fromValueBeforeEquals = lookup.descriptor.mapSubKeySource else {
                    warnings.append("Missing sub-key for map field '\(key)'")
                    return
                }
                guard let eq = entry.value.firstIndex(of: "=") else {
                    warnings.append(
                        "Malformed map value for '\(key)': expected KEY=VALUE, got '\(entry.value)'"
                    )
                    return
                }
                let sub = entry.value[entry.value.startIndex..<eq]
                    .trimmingCharacters(in: .whitespaces)
                let sval = entry.value[entry.value.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                if sub.isEmpty {
                    warnings.append("Empty sub-key for map field '\(key)'")
                    return
                }
                resolvedSubKey = sub
                resolvedValue = sval
            }

            acc.setMapEntry(key, subKey: resolvedSubKey, value: resolvedValue)
        }
    }
}

// MARK: - Accumulator

/// Internal mutable state used while walking layers. Stores the merged
/// result so far plus per-layer bookkeeping (which lists have been touched,
/// to implement the "first touch replaces" rule).
private struct Accumulator {
    var scalars: [String: String] = [:]
    var lists: [String: [String]] = [:]
    /// Ordered map per canonical key. `order` holds the insertion order of
    /// sub-keys; `values` holds each sub-key's current value.
    var maps: [String: OrderedStringMap] = [:]

    private var listsTouchedInCurrentLayer: Set<String> = []

    mutating func beginLayer() {
        listsTouchedInCurrentLayer.removeAll(keepingCapacity: true)
    }

    // Scalars
    mutating func setScalar(_ key: String, value: String) {
        scalars[key] = value
    }
    mutating func clearScalar(_ key: String) {
        scalars.removeValue(forKey: key)
    }

    // Lists
    func listTouchedInCurrentLayer(_ key: String) -> Bool {
        listsTouchedInCurrentLayer.contains(key)
    }
    mutating func markListTouchedInCurrentLayer(_ key: String) {
        listsTouchedInCurrentLayer.insert(key)
    }
    mutating func clearList(_ key: String) {
        lists[key] = []
    }
    mutating func appendList(_ key: String, value: String) {
        lists[key, default: []].append(value)
    }

    // Maps
    mutating func clearMap(_ key: String) {
        maps[key] = OrderedStringMap()
    }
    mutating func setMapEntry(_ key: String, subKey: String, value: String) {
        maps[key, default: OrderedStringMap()].set(subKey, value)
    }
    mutating func removeMapEntry(_ key: String, subKey: String) {
        maps[key]?.remove(subKey)
    }

    // Build final result

    func build(profileID: String, warnings: [String]) -> ResolvedProfile {
        var startup = ResolvedStartupFields()
        var live = ResolvedLiveFields()

        for (key, value) in scalars {
            assign(scalarKey: key, value: value, startup: &startup, live: &live)
        }
        for (key, list) in lists {
            assign(listKey: key, list: list, startup: &startup, live: &live)
        }
        for (key, map) in maps {
            assign(mapKey: key, map: map, startup: &startup, live: &live)
        }

        return ResolvedProfile(
            profileID: profileID,
            startup: startup,
            live: live,
            warnings: warnings
        )
    }

    private func assign(
        scalarKey key: String,
        value: String,
        startup: inout ResolvedStartupFields,
        live: inout ResolvedLiveFields
    ) {
        switch key {
        case "command": startup.command = value
        case "cwd": startup.cwd = value
        case "close-on-exit": startup.closeOnExit = value
        case "initial-x": startup.initialX = value
        case "initial-y": startup.initialY = value
        case "initial-width": startup.initialWidth = value
        case "initial-height": startup.initialHeight = value
        default:
            // Live scalar.
            live.scalars[key] = value
        }
    }

    private func assign(
        listKey key: String,
        list: [String],
        startup: inout ResolvedStartupFields,
        live: inout ResolvedLiveFields
    ) {
        switch key {
        case "args": startup.args = list
        default:
            live.lists[key] = list
        }
    }

    private func assign(
        mapKey key: String,
        map: OrderedStringMap,
        startup: inout ResolvedStartupFields,
        live: inout ResolvedLiveFields
    ) {
        switch key {
        case "env":
            startup.env = map.orderedEntries
        default:
            // Live maps (e.g. palette): consumer looks up by sub-key, order
            // does not matter, collapse to a plain dictionary.
            live.maps[key] = map.asDictionary
        }
    }
}

/// A small ordered map specialised for `String` values. Reassigning an
/// existing sub-key keeps its original position.
private struct OrderedStringMap {
    private(set) var order: [String] = []
    private(set) var values: [String: String] = [:]

    mutating func set(_ key: String, _ value: String) {
        if values[key] == nil {
            order.append(key)
        }
        values[key] = value
    }

    mutating func remove(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
    }

    var orderedEntries: [(key: String, value: String)] {
        order.map { ($0, values[$0] ?? "") }
    }

    var asDictionary: [String: String] {
        values
    }
}
