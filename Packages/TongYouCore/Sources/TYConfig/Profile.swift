import Foundation

// MARK: - Field classification

/// Whether a field is applied at pane creation (startup snapshot) or
/// continuously at render time (live, hot-reloadable).
public enum FieldLayer: Sendable, Equatable {
    case startup
    case live
}

/// Merge semantics of a field value across layers.
public enum FieldKind: Sendable, Equatable {
    /// Single value; lower layer replaces upper. Empty value resets/removes.
    case scalar
    /// Ordered list; first touch in a layer replaces the accumulated list,
    /// subsequent entries within the same layer append. Empty value clears.
    case list
    /// Table keyed by a sub-key; shallow merge across layers, sub-key wins.
    /// Empty value on the canonical key clears the whole table.
    case map
}

/// Where a map entry's sub-key is extracted from.
public enum MapSubKeySource: Sendable, Equatable {
    /// Sub-key is the suffix after a prefix on the entry key (e.g. `palette-0`
    /// → sub-key "0" under canonical "palette").
    case fromEntryKeySuffix(prefix: String)
    /// Sub-key is the portion of the value before the first `=` (e.g.
    /// `env = FOO=bar` → sub-key "FOO", sub-value "bar").
    case fromValueBeforeEquals
}

/// Static description of a recognised profile field.
public struct FieldDescriptor: Sendable, Equatable {
    public let canonicalKey: String
    public let kind: FieldKind
    public let layer: FieldLayer
    public let mapSubKeySource: MapSubKeySource?

    public init(
        canonicalKey: String,
        kind: FieldKind,
        layer: FieldLayer,
        mapSubKeySource: MapSubKeySource? = nil
    ) {
        self.canonicalKey = canonicalKey
        self.kind = kind
        self.layer = layer
        self.mapSubKeySource = mapSubKeySource
    }
}

// MARK: - Field registry

/// Whitelist of known profile fields and the rules for parsing an entry key
/// into (descriptor, sub-key). Phase 1 keeps the Live set minimal; later
/// phases expand it to cover every key handled by the global `Config` parser.
public enum FieldRegistry {

    /// Result of resolving an entry key.
    public struct Lookup: Sendable, Equatable {
        public let descriptor: FieldDescriptor
        public let subKey: String?
    }

    /// Exact-match table. Prefix-based keys (e.g. `palette-N`) are handled in
    /// `resolve(entryKey:)` below, not stored here directly.
    public static let descriptors: [String: FieldDescriptor] = {
        var table: [String: FieldDescriptor] = [:]

        // Startup — scalars
        for key in ["command", "cwd", "close-on-exit",
                    "initial-x", "initial-y",
                    "initial-width", "initial-height"] {
            table[key] = FieldDescriptor(
                canonicalKey: key,
                kind: .scalar,
                layer: .startup
            )
        }

        // Startup — list
        table["args"] = FieldDescriptor(
            canonicalKey: "args",
            kind: .list,
            layer: .startup
        )

        // Startup — map (env: sub-key = "FOO" from "FOO=bar")
        table["env"] = FieldDescriptor(
            canonicalKey: "env",
            kind: .map,
            layer: .startup,
            mapSubKeySource: .fromValueBeforeEquals
        )

        // Live — scalars (minimal Phase 1 set; extend in later phases).
        // `description` is profile metadata rather than a rendering field,
        // but parking it in the Live-scalars grab-bag lets the parser
        // accept the key (no "Unknown profile key" warning on the seeded
        // ssh / ssh-dev / ssh-prod templates) and gives future UI — e.g.
        // palette subtitle, sidebar tooltip — a single place to look it up.
        for key in ["theme",
                    "font-family", "font-size",
                    "background", "foreground",
                    "cursor-color", "cursor-text",
                    "cursor-style", "cursor-blink",
                    "selection-background", "selection-foreground",
                    "scrollback-limit", "tab-width",
                    "bell", "option-as-alt",
                    "description"] {
            table[key] = FieldDescriptor(
                canonicalKey: key,
                kind: .scalar,
                layer: .live
            )
        }

        // Live — map (palette: sub-key = "0" from entry key "palette-0").
        // The canonical form `palette` (no suffix) clears the whole table.
        table["palette"] = FieldDescriptor(
            canonicalKey: "palette",
            kind: .map,
            layer: .live,
            mapSubKeySource: .fromEntryKeySuffix(prefix: "palette-")
        )

        return table
    }()

    /// Reserved top-level keyword for inheritance. Never a profile field.
    public static let extendsKey = "extends"

    /// Resolve an entry key (as it appears in a file) into its descriptor and
    /// sub-key (if the field is a map).
    ///
    /// Returns `nil` when the key is unknown — callers should record a
    /// warning and ignore the entry.
    public static func resolve(entryKey: String) -> Lookup? {
        // 1. Exact match.
        if let desc = descriptors[entryKey] {
            return Lookup(descriptor: desc, subKey: nil)
        }

        // 2. Prefix match for map fields with `.fromEntryKeySuffix`.
        for desc in descriptors.values {
            guard case .fromEntryKeySuffix(let prefix) = desc.mapSubKeySource else {
                continue
            }
            if entryKey.hasPrefix(prefix) && entryKey.count > prefix.count {
                let suffix = String(entryKey.dropFirst(prefix.count))
                return Lookup(descriptor: desc, subKey: suffix)
            }
        }

        return nil
    }
}

// MARK: - Raw profile (pre-merge)

/// Parsed contents of a single profile file before any merge is applied.
public struct RawProfile: Sendable {
    public let id: String
    public let extendsID: String?
    /// Entries from the file, in order, with the `extends` line stripped.
    public let entries: [ConfigParser.Entry]

    public init(id: String, extendsID: String?, entries: [ConfigParser.Entry]) {
        self.id = id
        self.extendsID = extendsID
        self.entries = entries
    }
}

// MARK: - Resolved profile (post-merge)

/// Startup-layer fields as concrete values. Nil / empty means "not set by
/// the profile"; consumers supply their own defaults.
public struct ResolvedStartupFields: Sendable, Equatable {
    public var command: String?
    public var args: [String]
    public var cwd: String?
    /// Env entries preserved in insertion order. Later additions with the
    /// same key override earlier ones via the map merge rules.
    public var env: [(key: String, value: String)]
    public var closeOnExit: String?
    public var initialX: String?
    public var initialY: String?
    public var initialWidth: String?
    public var initialHeight: String?

    public init(
        command: String? = nil,
        args: [String] = [],
        cwd: String? = nil,
        env: [(key: String, value: String)] = [],
        closeOnExit: String? = nil,
        initialX: String? = nil,
        initialY: String? = nil,
        initialWidth: String? = nil,
        initialHeight: String? = nil
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

    public static func == (lhs: ResolvedStartupFields, rhs: ResolvedStartupFields) -> Bool {
        guard lhs.command == rhs.command,
              lhs.args == rhs.args,
              lhs.cwd == rhs.cwd,
              lhs.closeOnExit == rhs.closeOnExit,
              lhs.initialX == rhs.initialX,
              lhs.initialY == rhs.initialY,
              lhs.initialWidth == rhs.initialWidth,
              lhs.initialHeight == rhs.initialHeight,
              lhs.env.count == rhs.env.count else {
            return false
        }
        for (a, b) in zip(lhs.env, rhs.env) where a != b {
            return false
        }
        return true
    }
}

/// Live-layer fields in opaque, key-indexed form. The consumer (Phase 3)
/// reads individual keys and merges with the global `Config` defaults.
public struct ResolvedLiveFields: Sendable, Equatable {
    public var scalars: [String: String]
    public var lists: [String: [String]]
    /// Outer key = canonicalKey (e.g. "palette"), inner key = sub-key
    /// (e.g. "0"), inner value = raw value string.
    public var maps: [String: [String: String]]

    public init(
        scalars: [String: String] = [:],
        lists: [String: [String]] = [:],
        maps: [String: [String: String]] = [:]
    ) {
        self.scalars = scalars
        self.lists = lists
        self.maps = maps
    }

    /// Flatten the Live fields into a list of `ConfigParser.Entry` values so
    /// they can be re-parsed by existing `Config.from(entries:)` pipelines.
    /// Map fields whose sub-keys derive from the entry-key suffix (e.g.
    /// `palette-0`) are expanded; value-before-equals maps are not live
    /// fields today, so they're not handled here.
    public func asEntries() -> [ConfigParser.Entry] {
        var entries: [ConfigParser.Entry] = []
        for (key, value) in scalars {
            entries.append(ConfigParser.Entry(key: key, value: value))
        }
        for (key, list) in lists {
            for v in list {
                entries.append(ConfigParser.Entry(key: key, value: v))
            }
        }
        for (canonicalKey, table) in maps {
            guard let desc = FieldRegistry.descriptors[canonicalKey],
                  case .fromEntryKeySuffix(let prefix) = desc.mapSubKeySource else {
                continue
            }
            for (subKey, v) in table {
                entries.append(ConfigParser.Entry(key: "\(prefix)\(subKey)", value: v))
            }
        }
        return entries
    }
}

/// Output of `ProfileMerger.resolve`.
public struct ResolvedProfile: Sendable {
    public let profileID: String
    public var startup: ResolvedStartupFields
    public var live: ResolvedLiveFields
    /// Non-fatal issues encountered during resolution (e.g. unknown keys).
    /// Phase 1 returns these so the consumer can log; TYConfig stays dep-free.
    public var warnings: [String]

    public init(
        profileID: String,
        startup: ResolvedStartupFields = ResolvedStartupFields(),
        live: ResolvedLiveFields = ResolvedLiveFields(),
        warnings: [String] = []
    ) {
        self.profileID = profileID
        self.startup = startup
        self.live = live
        self.warnings = warnings
    }
}
