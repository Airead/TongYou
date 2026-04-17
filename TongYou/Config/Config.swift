import Foundation
import TYTerminal

/// Disambiguate from QuickDraw's RGBColor in ApplicationServices.
typealias RGBColor = TYTerminal.RGBColor

/// Terminal configuration with sensible defaults.
/// All fields can be overridden by the user's config file.
struct Config: Equatable {

    // MARK: - Font

    var fontFamily: String = "Menlo"
    var fontSize: Int = 14

    // MARK: - Theme

    /// Built-in theme name. When set, provides base colors that can be overridden.
    var theme: String? = "iterm2-dark-background"

    // MARK: - Colors

    var background: RGBColor = RGBColor(0x1e, 0x1e, 0x26)
    var foreground: RGBColor = RGBColor(0xdc, 0xdc, 0xdc)
    /// Palette overrides: index → color. Only overridden entries are stored.
    var palette: [Int: RGBColor] = [:]
    var cursorColor: RGBColor?
    var cursorText: RGBColor?
    var selectionBackground: RGBColor?
    var selectionForeground: RGBColor?

    // MARK: - Behavior

    var optionAsAlt: Bool = true
    var cursorStyle: CursorStyle = .block
    var cursorBlink: Bool = false
    var scrollbackLimit: Int = 10000
    var tabWidth: Int = 8
    var bell: BellMode = .audible

    // MARK: - Tab Bar

    var tabBarVisibility: TabBarVisibility = .auto

    // MARK: - Keybindings

    var keybindings: [Keybinding] = []

    /// Programs that automatically receive non-Cmd keybindings when in foreground.
    var autoPassthroughPrograms: Set<String> = []

    // MARK: - Draft Session

    /// Create a Draft session automatically on launch.
    var draftEnabled: Bool = true

    // MARK: - Daemon

    /// Automatically connect to tongyou daemon on launch.
    var autoConnectDaemon: Bool = false

    // MARK: - Debug

    var debugMetrics: Bool = false

    // MARK: - Static

    /// Default configuration (all fields at their initial values).
    static let `default` = Config()

    /// Apply parsed key-value entries to build a config.
    /// Later entries override earlier ones; list keys (keybind) accumulate.
    /// Theme is applied first as a base; explicit color keys override theme colors.
    static func from(entries: [ConfigParser.Entry]) -> Config {
        var config = Config()
        var customKeybindings: [Keybinding] = []
        // Track which color keys were explicitly set so they override theme.
        var explicitColorKeys: Set<String> = []

        for entry in entries {
            do {
                let isColorKey = Self.colorKeys.contains(entry.key)
                    || entry.key.hasPrefix("palette-")
                if isColorKey && !entry.value.isEmpty {
                    explicitColorKeys.insert(entry.key)
                }
                try config.apply(key: entry.key, value: entry.value,
                                 keybindings: &customKeybindings)
            } catch {
                print("[config] warning: \(error)")
            }
        }

        // Apply theme as base, then re-apply explicit overrides on top.
        if let themeName = config.theme,
           let theme = BuiltinTheme.named(themeName) {
            config.applyTheme(theme, excluding: explicitColorKeys)
        }

        // Keybindings are defined entirely by the config file.
        // If the file contains no keybind entries, no shortcuts are registered.
        config.keybindings = customKeybindings

        return config
    }

    /// Mapping from config key to optional-color field on Config.
    /// Single source of truth for color key names — used by both `from(entries:)`
    /// and `applyTheme(_:excluding:)`.
    private static let optionalColorMappings: [(key: String, path: WritableKeyPath<Config, RGBColor?>, themePath: KeyPath<Theme, RGBColor>)] = [
        ("cursor-color",          \.cursorColor,          \.cursorColor),
        ("cursor-text",           \.cursorText,           \.cursorText),
        ("selection-background",  \.selectionBackground,  \.selectionBackground),
        ("selection-foreground",  \.selectionForeground,  \.selectionForeground),
    ]

    /// All color config keys that can override theme values.
    private static let colorKeys: Set<String> = {
        var keys: Set<String> = ["background", "foreground"]
        for mapping in optionalColorMappings {
            keys.insert(mapping.key)
        }
        return keys
    }()
}

// MARK: - Apply Key-Value

extension Config {

    mutating func apply(
        key: String,
        value: String,
        keybindings: inout [Keybinding]
    ) throws {
        switch key {
        // Font
        case "font-family":
            fontFamily = value.isEmpty ? Config.default.fontFamily : stripQuotes(value)
        case "font-size":
            if value.isEmpty {
                fontSize = Config.default.fontSize
            } else {
                guard let v = Int(value), v > 0, v <= 200 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                fontSize = v
            }

        // Theme
        case "theme":
            theme = value.isEmpty ? nil : value

        // Colors
        case "background":
            background = value.isEmpty ? Config.default.background : try parseColor(value, key: key)
        case "foreground":
            foreground = value.isEmpty ? Config.default.foreground : try parseColor(value, key: key)
        case "cursor-color":
            cursorColor = value.isEmpty ? nil : try parseColor(value, key: key)
        case "cursor-text":
            cursorText = value.isEmpty ? nil : try parseColor(value, key: key)
        case "selection-background":
            selectionBackground = value.isEmpty ? nil : try parseColor(value, key: key)
        case "selection-foreground":
            selectionForeground = value.isEmpty ? nil : try parseColor(value, key: key)

        // Palette overrides: palette-0 through palette-255
        case _ where key.hasPrefix("palette-"):
            let indexStr = String(key.dropFirst("palette-".count))
            guard let index = Int(indexStr), (0...255).contains(index) else {
                throw ConfigError.invalidValue(key: key, value: value)
            }
            if value.isEmpty {
                palette.removeValue(forKey: index)
            } else {
                palette[index] = try parseColor(value, key: key)
            }

        // Behavior
        case "option-as-alt":
            optionAsAlt = value.isEmpty ? Config.default.optionAsAlt : try parseBool(value, key: key)
        case "cursor-style":
            if value.isEmpty {
                cursorStyle = Config.default.cursorStyle
            } else {
                guard let style = CursorStyle(rawValue: value) else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                cursorStyle = style
            }
        case "cursor-blink":
            cursorBlink = value.isEmpty ? Config.default.cursorBlink : try parseBool(value, key: key)
        case "scrollback-limit":
            if value.isEmpty {
                scrollbackLimit = Config.default.scrollbackLimit
            } else {
                guard let v = Int(value), v >= 0 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                scrollbackLimit = v
            }
        case "tab-width":
            if value.isEmpty {
                tabWidth = Config.default.tabWidth
            } else {
                guard let v = Int(value), v > 0, v <= 32 else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                tabWidth = v
            }
        case "bell":
            if value.isEmpty {
                bell = Config.default.bell
            } else {
                guard let mode = BellMode(rawValue: value) else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                bell = mode
            }

        // Tab bar
        case "tab-bar":
            if value.isEmpty {
                tabBarVisibility = Config.default.tabBarVisibility
            } else {
                guard let vis = TabBarVisibility(rawValue: value) else {
                    throw ConfigError.invalidValue(key: key, value: value)
                }
                tabBarVisibility = vis
            }

        // Keybindings (accumulate)
        case "keybind":
            if !value.isEmpty {
                keybindings.append(try Keybinding.parse(value))
            }

        // Auto passthrough programs (comma-separated)
        case "auto-passthrough-programs":
            if value.isEmpty {
                autoPassthroughPrograms = []
            } else {
                autoPassthroughPrograms = Set(
                    value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                )
            }

        // Draft session
        case "draft-enabled":
            draftEnabled = value.isEmpty ? Config.default.draftEnabled : try parseBool(value, key: key)

        // Daemon
        case "auto-connect-daemon":
            autoConnectDaemon = value.isEmpty ? Config.default.autoConnectDaemon : try parseBool(value, key: key)

        // Debug
        case "debug-metrics":
            debugMetrics = value.isEmpty ? false : try parseBool(value, key: key)

        default:
            // Unknown keys are silently ignored for forward compatibility
            break
        }
    }

    /// Apply a theme's colors, skipping any keys the user explicitly set.
    mutating func applyTheme(_ theme: Theme, excluding explicitKeys: Set<String>) {
        if !explicitKeys.contains("background") {
            background = theme.background
        }
        if !explicitKeys.contains("foreground") {
            foreground = theme.foreground
        }
        for mapping in Self.optionalColorMappings where !explicitKeys.contains(mapping.key) {
            self[keyPath: mapping.path] = theme[keyPath: mapping.themePath]
        }
        for i in 0..<16 where !explicitKeys.contains("palette-\(i)") {
            palette[i] = theme.palette[i]
        }
    }
}

// MARK: - Value Parsing Helpers

/// Cursor style as a config-file enum string.
enum CursorStyle: String, Equatable {
    case block
    case underline
    case bar

    /// Convert to the rendering-layer CursorShape.
    var shape: CursorShape {
        switch self {
        case .block: .block
        case .underline: .underline
        case .bar: .bar
        }
    }
}

/// Bell mode.
enum BellMode: String, Equatable {
    case audible
    case visual
    case none
}

/// Sidebar visibility mode.
enum SidebarVisibility: String, Equatable {
    /// Show sidebar only when more than one session exists.
    case auto
    /// Always show the sidebar.
    case always
    /// Never show the sidebar.
    case never
}

/// Tab bar visibility mode.
enum TabBarVisibility: String, Equatable {
    /// Show tab bar only when more than one tab is open.
    case auto
    /// Always show the tab bar.
    case always
    /// Never show the tab bar.
    case never
}

extension RGBColor {
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.init(r: r, g: g, b: b)
    }

    /// Convert to SIMD4<UInt8> with full alpha.
    var simd4: SIMD4<UInt8> { SIMD4<UInt8>(r, g, b, 255) }

    /// Parse a 6-digit hex string (no # prefix).
    init(hex: String) throws {
        guard hex.count == 6,
              let value = UInt32(hex, radix: 16) else {
            throw ConfigError.invalidValue(key: "color", value: hex)
        }
        self.init(r: UInt8((value >> 16) & 0xFF),
                  g: UInt8((value >> 8) & 0xFF),
                  b: UInt8(value & 0xFF))
    }
}

private func parseColor(_ value: String, key: String) throws -> RGBColor {
    // Strip optional # prefix for convenience
    let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
    do {
        return try RGBColor(hex: hex)
    } catch {
        throw ConfigError.invalidValue(key: key, value: value)
    }
}

private func parseBool(_ value: String, key: String) throws -> Bool {
    switch value.lowercased() {
    case "true": return true
    case "false": return false
    default: throw ConfigError.invalidValue(key: key, value: value)
    }
}

private func stripQuotes(_ value: String) -> String {
    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
        return String(value.dropFirst().dropLast())
    }
    return value
}
