import AppKit

/// Options parsed from `[key=value,flag]` syntax in command actions.
///
/// Examples:
/// - `run_local_command[pane]:git:status`       → `pane: true`
/// - `run_local_command[output=pane]:git:log`    → `output: "pane"`
struct CommandOptions: Equatable, Sendable {
    private var storage: [String: String] = [:]

    nonisolated static let empty = CommandOptions()

    /// Check if a boolean flag is set (e.g. `[pane]`).
    func has(_ key: String) -> Bool {
        storage[key] != nil
    }

    /// Get a value (e.g. `[output=pane]` → `value("output") == "pane"`).
    func value(_ key: String) -> String? {
        storage[key]
    }

    /// Whether the command output should be shown in a floating pane.
    var showInPane: Bool {
        has("pane") || value("output") == "pane"
    }

    var isEmpty: Bool { storage.isEmpty }

    /// Parse from a string like `"pane,output=foo"`.
    static func parse(_ raw: String) -> CommandOptions {
        var opts = CommandOptions()
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIdx])
                let val = String(trimmed[trimmed.index(after: eqIdx)...])
                opts.storage[key] = val
            } else {
                // Boolean flag: store with empty-string value.
                opts.storage[trimmed] = ""
            }
        }
        return opts
    }

    /// Serialize back to config string. Empty options return nil.
    func formatted() -> String? {
        guard !storage.isEmpty else { return nil }
        let parts = storage.sorted(by: { $0.key < $1.key }).map { key, value in
            value.isEmpty ? key : "\(key)=\(value)"
        }
        return parts.joined(separator: ",")
    }
}

/// A keyboard shortcut bound to a terminal action.
struct Keybinding: Equatable {

    /// Modifier keys (command, shift, control, option).
    let modifiers: NSEvent.ModifierFlags

    /// The key character (lowercased, ignoring modifiers). e.g. "t", "w", "left".
    let key: String

    /// The action to perform.
    let action: Action

    /// Actions that can be triggered by keybindings.
    enum Action: Equatable {
        // Session management
        case newSession
        case closeSession
        case previousSession
        case nextSession
        case toggleSidebar
        // Tab management
        case newTab
        case closeTab
        case previousTab
        case nextTab
        case gotoTab(Int)  // 1-based tab number
        case copy
        case paste
        case search
        case searchNext
        case searchPrevious
        case resetFontSize
        case increaseFontSize
        case decreaseFontSize
        // Pane management
        case splitVertical
        case splitHorizontal
        case closePane
        case focusPane(FocusDirection)
        // Pane resize
        case growPane
        case shrinkPane
        // Floating pane management
        case newFloatingPane
        case toggleOrCreateFloatingPane
        // Remote session management
        case listRemoteSessions
        case newRemoteSession
        case showSessionPicker
        case detachSession
        case renameSession
        case runInPlace(command: String, arguments: [String])
        case runLocalCommand(command: String, arguments: [String], options: CommandOptions)
        case runRemoteCommand(command: String, arguments: [String], options: CommandOptions)
        // Pass through to PTY (disables the keybinding)
        case unbind

        /// Raw string used in config files.
        var rawValue: String {
            switch self {
            case .newSession: "new_session"
            case .closeSession: "close_session"
            case .previousSession: "previous_session"
            case .nextSession: "next_session"
            case .toggleSidebar: "toggle_sidebar"
            case .newTab: "new_tab"
            case .closeTab: "close_tab"
            case .previousTab: "previous_tab"
            case .nextTab: "next_tab"
            case .gotoTab(let n): "goto_tab:\(n)"
            case .copy: "copy"
            case .paste: "paste"
            case .search: "search"
            case .searchNext: "search_next"
            case .searchPrevious: "search_previous"
            case .resetFontSize: "reset_font_size"
            case .increaseFontSize: "increase_font_size"
            case .decreaseFontSize: "decrease_font_size"
            case .splitVertical: "split_vertical"
            case .splitHorizontal: "split_horizontal"
            case .closePane: "close_pane"
            case .focusPane(let dir):
                switch dir {
                case .left: "focus_pane_left"
                case .right: "focus_pane_right"
                case .up: "focus_pane_up"
                case .down: "focus_pane_down"
                }
            case .growPane: "grow_pane"
            case .shrinkPane: "shrink_pane"
            case .newFloatingPane: "new_floating_pane"
            case .toggleOrCreateFloatingPane: "toggle_or_create_floating_pane"
            case .listRemoteSessions: "list_remote_sessions"
            case .newRemoteSession: "new_remote_session"
            case .showSessionPicker: "show_session_picker"
            case .detachSession: "detach_session"
            case .renameSession: "rename_session"
            case .runInPlace(let cmd, let args):
                Self.formatPrefixedAction(prefix: "run_in_place", command: cmd, arguments: args)
            case .runLocalCommand(let cmd, let args, let opts):
                Self.formatPrefixedAction(prefix: "run_local_command", command: cmd, arguments: args, options: opts)
            case .runRemoteCommand(let cmd, let args, let opts):
                Self.formatPrefixedAction(prefix: "run_remote_command", command: cmd, arguments: args, options: opts)
            case .unbind: "unbind"
            }
        }

        // MARK: - Helpers

        private static func formatPrefixedAction(
            prefix: String, command: String, arguments: [String],
            options: CommandOptions = .empty
        ) -> String {
            let optsPart = options.formatted().map { "[\($0)]" } ?? ""
            if arguments.isEmpty {
                return "\(prefix)\(optsPart):\(command)"
            } else {
                return "\(prefix)\(optsPart):\(command):\(arguments.joined(separator: ","))"
            }
        }

        /// Parse a prefixed action with optional `[options]` syntax.
        ///
        /// Matches: `prefix:cmd`, `prefix:cmd:args`, `prefix[opts]:cmd`, `prefix[opts]:cmd:args`
        private static func parsePrefixedAction(
            rawValue: String, prefix: String
        ) -> (command: String, arguments: [String], options: CommandOptions)? {
            guard rawValue.hasPrefix(prefix) else { return nil }
            let afterPrefix = rawValue.dropFirst(prefix.count)

            let options: CommandOptions
            let rest: Substring

            if afterPrefix.hasPrefix("[") {
                // Parse [options] block.
                guard let closeBracket = afterPrefix.firstIndex(of: "]") else { return nil }
                let optsStr = String(afterPrefix[afterPrefix.index(after: afterPrefix.startIndex)..<closeBracket])
                options = CommandOptions.parse(optsStr)
                let afterBracket = afterPrefix[afterPrefix.index(after: closeBracket)...]
                guard afterBracket.hasPrefix(":") else { return nil }
                rest = afterBracket.dropFirst()  // drop the ":"
            } else if afterPrefix.hasPrefix(":") {
                options = .empty
                rest = afterPrefix.dropFirst()   // drop the ":"
            } else {
                return nil
            }

            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            let command = String(parts[0])
            let arguments: [String]
            if parts.count > 1 {
                arguments = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            } else {
                arguments = []
            }
            return (command, arguments, options)
        }

        /// Map to TabAction for actions that pass straight through to the window.
        var tabAction: TabAction? {
            switch self {
            case .newSession: .newSession
            case .closeSession: .closeSession
            case .previousSession: .previousSession
            case .nextSession: .nextSession
            case .toggleSidebar: .toggleSidebar
            case .newTab: .newTab
            case .closeTab: .closeTab
            case .previousTab: .previousTab
            case .nextTab: .nextTab
            case .gotoTab(let n): .gotoTab(n)
            case .splitVertical: .splitVertical
            case .splitHorizontal: .splitHorizontal
            case .closePane: .closePane
            case .focusPane(let dir): .focusPane(dir)
            case .growPane: .growPane
            case .shrinkPane: .shrinkPane
            case .newFloatingPane: .newFloatingPane
            case .toggleOrCreateFloatingPane: .toggleOrCreateFloatingPane
            case .listRemoteSessions: .listRemoteSessions
            case .newRemoteSession: .newRemoteSession
            case .showSessionPicker: .showSessionPicker
            case .detachSession: .detachSession
            case .renameSession: .renameSession
            case .runInPlace(let cmd, let args): .runInPlace(command: cmd, arguments: args)
            case .runLocalCommand(let cmd, let args, let opts): .runLocalCommand(command: cmd, arguments: args, options: opts)
            case .runRemoteCommand(let cmd, let args, let opts): .runRemoteCommand(command: cmd, arguments: args, options: opts)
            case .copy, .paste, .search, .searchNext, .searchPrevious,
                 .resetFontSize, .increaseFontSize, .decreaseFontSize,
                 .unbind:
                nil
            }
        }

        /// Parse from config string.
        init?(rawValue: String) {
            switch rawValue {
            case "new_session": self = .newSession
            case "close_session": self = .closeSession
            case "previous_session": self = .previousSession
            case "next_session": self = .nextSession
            case "toggle_sidebar": self = .toggleSidebar
            case "new_tab": self = .newTab
            case "close_tab": self = .closeTab
            case "previous_tab": self = .previousTab
            case "next_tab": self = .nextTab
            case "copy": self = .copy
            case "paste": self = .paste
            case "search": self = .search
            case "search_next": self = .searchNext
            case "search_previous": self = .searchPrevious
            case "reset_font_size": self = .resetFontSize
            case "increase_font_size": self = .increaseFontSize
            case "decrease_font_size": self = .decreaseFontSize
            case "split_vertical": self = .splitVertical
            case "split_horizontal": self = .splitHorizontal
            case "close_pane": self = .closePane
            case "focus_pane_left": self = .focusPane(.left)
            case "focus_pane_right": self = .focusPane(.right)
            case "focus_pane_up": self = .focusPane(.up)
            case "focus_pane_down": self = .focusPane(.down)
            case "grow_pane": self = .growPane
            case "shrink_pane": self = .shrinkPane
            case "new_floating_pane": self = .newFloatingPane
            case "toggle_or_create_floating_pane": self = .toggleOrCreateFloatingPane
            case "list_remote_sessions": self = .listRemoteSessions
            case "new_remote_session": self = .newRemoteSession
            case "show_session_picker": self = .showSessionPicker
            case "detach_session": self = .detachSession
            case "rename_session": self = .renameSession
            case "unbind": self = .unbind
            default:
                if rawValue.hasPrefix("goto_tab:"),
                   let n = Int(rawValue.dropFirst("goto_tab:".count)),
                   (1...9).contains(n) {
                    self = .gotoTab(n)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_in_place") {
                    self = .runInPlace(command: parsed.command, arguments: parsed.arguments)
                    return  // run_in_place does not use options (it always takes over the pane)
                }
                // "run_local_command" is the canonical name; "run_command" is accepted for backwards compatibility.
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_local_command") {
                    self = .runLocalCommand(command: parsed.command, arguments: parsed.arguments, options: parsed.options)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_command") {
                    self = .runLocalCommand(command: parsed.command, arguments: parsed.arguments, options: parsed.options)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_remote_command") {
                    self = .runRemoteCommand(command: parsed.command, arguments: parsed.arguments, options: parsed.options)
                    return
                }
                return nil
            }
        }
    }

    /// Default keybindings.
    static let defaults: [Keybinding] = [
        // Session management
        Keybinding(modifiers: .command, key: "i", action: .newSession),
        Keybinding(modifiers: .command, key: "up", action: .previousSession),
        Keybinding(modifiers: .command, key: "k", action: .previousSession),
        Keybinding(modifiers: .command, key: "down", action: .nextSession),
        Keybinding(modifiers: .command, key: "j", action: .nextSession),
        Keybinding(modifiers: .command, key: "b", action: .toggleSidebar),
        // Tab management
        Keybinding(modifiers: .command, key: "t", action: .newTab),
        Keybinding(modifiers: .command, key: "w", action: .closePane),
        Keybinding(modifiers: .command, key: "h", action: .previousTab),
        Keybinding(modifiers: .command, key: "l", action: .nextTab),
        Keybinding(modifiers: [.command, .shift], key: "[", action: .previousTab),
        Keybinding(modifiers: [.command, .shift], key: "]", action: .nextTab),
        // Cmd+1 through Cmd+9
        Keybinding(modifiers: .command, key: "1", action: .gotoTab(1)),
        Keybinding(modifiers: .command, key: "2", action: .gotoTab(2)),
        Keybinding(modifiers: .command, key: "3", action: .gotoTab(3)),
        Keybinding(modifiers: .command, key: "4", action: .gotoTab(4)),
        Keybinding(modifiers: .command, key: "5", action: .gotoTab(5)),
        Keybinding(modifiers: .command, key: "6", action: .gotoTab(6)),
        Keybinding(modifiers: .command, key: "7", action: .gotoTab(7)),
        Keybinding(modifiers: .command, key: "8", action: .gotoTab(8)),
        Keybinding(modifiers: .command, key: "9", action: .gotoTab(9)),
        // Clipboard
        Keybinding(modifiers: .command, key: "c", action: .copy),
        Keybinding(modifiers: .command, key: "v", action: .paste),
        // Search
        Keybinding(modifiers: .command, key: "f", action: .search),
        Keybinding(modifiers: .command, key: "g", action: .searchNext),
        Keybinding(modifiers: [.command, .shift], key: "g", action: .searchPrevious),
        // Font size
        Keybinding(modifiers: .command, key: "0", action: .resetFontSize),
        Keybinding(modifiers: .command, key: "+", action: .increaseFontSize),
        Keybinding(modifiers: .command, key: "-", action: .decreaseFontSize),
        // Pane management
        Keybinding(modifiers: .command, key: "d", action: .splitVertical),
        Keybinding(modifiers: [.command, .shift], key: "d", action: .splitHorizontal),
        Keybinding(modifiers: [.command, .shift], key: "w", action: .closeTab),
        Keybinding(modifiers: [.command, .option], key: "left", action: .focusPane(.left)),
        Keybinding(modifiers: [.command, .option], key: "right", action: .focusPane(.right)),
        Keybinding(modifiers: [.command, .option], key: "up", action: .focusPane(.up)),
        Keybinding(modifiers: [.command, .option], key: "down", action: .focusPane(.down)),
        // Pane resize
        Keybinding(modifiers: .option, key: "=", action: .growPane),
        Keybinding(modifiers: .option, key: "-", action: .shrinkPane),
        // Floating pane management
        Keybinding(modifiers: .option, key: "f", action: .toggleOrCreateFloatingPane),
        Keybinding(modifiers: .option, key: "n", action: .newFloatingPane),
        // In-place overlay
        Keybinding(modifiers: .option, key: "m", action: .runInPlace(command: "lazygit", arguments: [])),
        // Remote session management
        Keybinding(modifiers: .command, key: "y", action: .listRemoteSessions),
        Keybinding(modifiers: [.command, .shift], key: "i", action: .newRemoteSession),
        Keybinding(modifiers: .command, key: "r", action: .showSessionPicker),
        Keybinding(modifiers: [.command, .shift], key: "k", action: .detachSession),
        Keybinding(modifiers: [.command, .shift], key: "r", action: .renameSession),
    ]

    /// Parse a keybinding string like "cmd+shift+t=new_tab".
    static func parse(_ string: String) throws -> Keybinding {
        guard let eqIndex = string.lastIndex(of: "=") else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }

        let combo = string[string.startIndex..<eqIndex]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let actionStr = string[string.index(after: eqIndex)...]
            .trimmingCharacters(in: .whitespaces)

        guard let action = Action(rawValue: actionStr) else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }

        let parts = combo.split(separator: "+").map(String.init)
        guard !parts.isEmpty else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }

        var modifiers: NSEvent.ModifierFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command", "super":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "opt", "option":
                modifiers.insert(.option)
            default:
                keyPart = part
            }
        }

        guard let raw = keyPart, !raw.isEmpty else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }

        // Resolve named keys to their character equivalents.
        let key = Self.namedKeys[raw] ?? raw

        return Keybinding(modifiers: modifiers, key: key, action: action)
    }

    /// Look up the action for a key event in a list of keybindings.
    static func match(
        event: NSEvent,
        in bindings: [Keybinding]
    ) -> Action? {
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""

        for binding in bindings {
            if eventMods == binding.modifiers && eventKey == binding.key {
                return binding.action
            }
            // Fallback: when Shift is held, charactersIgnoringModifiers returns
            // the shifted symbol (e.g. "{" for "["). Allow matching against the
            // unshifted base character so configs like cmd+shift+[=... work.
            if eventMods == binding.modifiers,
               eventMods.contains(.shift),
               let baseKey = Self.shiftedToBase[eventKey],
               baseKey == binding.key {
                return binding.action
            }
        }
        return nil
    }

    /// Maps named key aliases to their character equivalents.
    /// This allows configs to use readable names for keys that conflict with
    /// the config syntax (e.g. `+` is the modifier separator, `=` is the
    /// action separator).
    private static let namedKeys: [String: String] = [
        "plus": "+", "equal": "=", "minus": "-",
        "space": " ", "backslash": "\\", "slash": "/",
        "comma": ",", "period": ".", "semicolon": ";",
    ]

    /// Maps common shifted ASCII symbols back to their base key characters.
    /// This allows bindings like `cmd+shift+[` to match even though
    /// `charactersIgnoringModifiers` returns `{` when Shift is active.
    private static let shiftedToBase: [String: String] = [
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/", "~": "`", "!": "1",
        "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=",
    ]
}

// MARK: - ModifierFlags Equatable for matching

extension NSEvent.ModifierFlags {
    /// The modifier flags we care about for keybinding matching.
    static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
}
