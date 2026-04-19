import Foundation

/// Errors raised while resolving a profile.
public enum ProfileResolveError: Error, CustomStringConvertible, Sendable {
    case profileNotFound(id: String)
    case circularExtends(chain: [String])
    case extendsDepthExceeded(chain: [String])
    case invalidOverrideLine(index: Int, line: String)
    case undefinedVariable(name: String)

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
        case .undefinedVariable(let name):
            return "Undefined variable in profile: '${\(name)}'"
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
    ///
    /// `variables` feeds `${NAME}` placeholders in scalar values, list items,
    /// and map values (including env values). Map sub-keys / env keys are not
    /// expanded. `$$` escapes to a literal `$`. Unknown `${NAME}` throws
    /// `.undefinedVariable` so misconfiguration fails loudly instead of, say,
    /// SSH-ing to a literal `${HOST}`.
    ///
    /// Set `expandVariables` to `false` to skip the substitution pass entirely
    /// and return the raw accumulator output verbatim. Rendering-time lookups
    /// (`ProfileLoader.resolvedLive`) use this to get live fields like
    /// `background` out of profiles whose chain references `${HOST}` in
    /// unrelated fields — otherwise the missing variable would throw and the
    /// pane would silently lose all live-field overrides.
    public func resolve(
        profileID: String,
        overrides: [String] = [],
        variables: [String: String] = [:],
        expandVariables: Bool = true
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

        var resolved = accumulator.build(profileID: profileID, warnings: warnings)
        if expandVariables {
            try Self.expandVariables(in: &resolved, variables: variables)
        }
        return resolved
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

    // MARK: - Variable expansion

    private static func expandVariables(
        in resolved: inout ResolvedProfile,
        variables: [String: String]
    ) throws {
        try expandStartup(&resolved.startup, variables: variables)
        try expandLive(&resolved.live, variables: variables)
    }

    private static func expandStartup(
        _ s: inout ResolvedStartupFields,
        variables: [String: String]
    ) throws {
        if let v = s.command { s.command = try expand(v, variables: variables) }
        if let v = s.cwd { s.cwd = try expand(v, variables: variables) }
        if let v = s.closeOnExit { s.closeOnExit = try expand(v, variables: variables) }
        if let v = s.initialX { s.initialX = try expand(v, variables: variables) }
        if let v = s.initialY { s.initialY = try expand(v, variables: variables) }
        if let v = s.initialWidth { s.initialWidth = try expand(v, variables: variables) }
        if let v = s.initialHeight { s.initialHeight = try expand(v, variables: variables) }

        var newArgs: [String] = []
        newArgs.reserveCapacity(s.args.count)
        for arg in s.args {
            newArgs.append(try expand(arg, variables: variables))
        }
        s.args = newArgs

        var newEnv: [(key: String, value: String)] = []
        newEnv.reserveCapacity(s.env.count)
        for pair in s.env {
            newEnv.append((key: pair.key, value: try expand(pair.value, variables: variables)))
        }
        s.env = newEnv
    }

    private static func expandLive(
        _ live: inout ResolvedLiveFields,
        variables: [String: String]
    ) throws {
        var newScalars: [String: String] = [:]
        newScalars.reserveCapacity(live.scalars.count)
        for (k, v) in live.scalars {
            newScalars[k] = try expand(v, variables: variables)
        }
        live.scalars = newScalars

        var newLists: [String: [String]] = [:]
        newLists.reserveCapacity(live.lists.count)
        for (k, list) in live.lists {
            var items: [String] = []
            items.reserveCapacity(list.count)
            for v in list {
                items.append(try expand(v, variables: variables))
            }
            newLists[k] = items
        }
        live.lists = newLists

        var newMaps: [String: [String: String]] = [:]
        newMaps.reserveCapacity(live.maps.count)
        for (canonicalKey, table) in live.maps {
            var newTable: [String: String] = [:]
            newTable.reserveCapacity(table.count)
            for (subKey, v) in table {
                newTable[subKey] = try expand(v, variables: variables)
            }
            newMaps[canonicalKey] = newTable
        }
        live.maps = newMaps
    }

    /// Expand `${NAME}` placeholders in `s`. `$$` escapes to a literal `$`.
    /// A `$` that is not part of `${NAME}` or `$$` is preserved verbatim
    /// (e.g. `$5`, `${`, `${}`). Variable names are case-sensitive and must
    /// match `[A-Za-z_][A-Za-z0-9_]*`; a well-formed `${NAME}` whose key is
    /// missing from `variables` throws `.undefinedVariable`.
    private static func expand(
        _ s: String,
        variables: [String: String]
    ) throws -> String {
        if !s.contains("$") { return s }

        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch != "$" {
                result.append(ch)
                i = s.index(after: i)
                continue
            }
            let next = s.index(after: i)
            if next == s.endIndex {
                // Trailing lone $
                result.append("$")
                i = next
                continue
            }
            let nc = s[next]
            if nc == "$" {
                result.append("$")
                i = s.index(after: next)
                continue
            }
            if nc == "{" {
                let nameStart = s.index(after: next)
                var j = nameStart
                while j < s.endIndex && s[j] != "}" {
                    j = s.index(after: j)
                }
                if j < s.endIndex {
                    let name = String(s[nameStart..<j])
                    if isValidVariableName(name) {
                        guard let value = variables[name] else {
                            throw ProfileResolveError.undefinedVariable(name: name)
                        }
                        result.append(value)
                        i = s.index(after: j)
                        continue
                    }
                }
                // Unterminated or invalid name → keep literally.
            }
            // Plain $ followed by something we don't special-case.
            result.append("$")
            i = next
        }
        return result
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for (idx, c) in name.enumerated() {
            guard let a = c.asciiValue else { return false }
            let isUpper = a >= 0x41 && a <= 0x5A
            let isLower = a >= 0x61 && a <= 0x7A
            let isDigit = a >= 0x30 && a <= 0x39
            let isUnderscore = a == 0x5F
            if idx == 0 {
                if !(isUpper || isLower || isUnderscore) { return false }
            } else {
                if !(isUpper || isLower || isDigit || isUnderscore) { return false }
            }
        }
        return true
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
