import AppKit
import TYTerminal

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

    /// Whether the floating pane should close automatically when the command exits.
    /// When false (default), the pane stays open for the user to read output;
    /// ESC closes it, Enter re-runs the command.
    var closeOnExit: Bool {
        has("close_on_exit")
    }

    /// Whether the command should run in local sessions.
    var runsLocal: Bool { has("local") }

    /// Whether the command should run in remote sessions.
    var runsRemote: Bool { has("remote") }

    /// Whether the command should always run locally, even in remote sessions.
    var alwaysLocal: Bool { has("always_local") }

    /// Build a custom floating pane frame from `x`, `y`, `w`, `h` options.
    /// Returns nil if none of these options are set (use default frame).
    /// Values are normalized (0–1); width/height are clamped to [minSize..1.0].
    var paneFrame: CGRect? {
        guard has("x") || has("y") || has("w") || has("h") else { return nil }
        let defaultFrame = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let x = value("x").flatMap(Double.init) ?? defaultFrame.origin.x
        let y = value("y").flatMap(Double.init) ?? defaultFrame.origin.y
        let w = min(max(value("w").flatMap(Double.init) ?? defaultFrame.width, 0.1), 1.0)
        let h = min(max(value("h").flatMap(Double.init) ?? defaultFrame.height, 0.1), 1.0)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var isEmpty: Bool { storage.isEmpty }

    /// Set a boolean flag if it is not already present.
    mutating func setIfMissing(_ key: String) {
        if storage[key] == nil {
            storage[key] = ""
        }
    }

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
        // Pane reordering (plan §P4.3)
        case movePane(FocusDirection)
        // Pane resize
        case growPane
        case shrinkPane
        // Pane zoom / monocle
        case toggleZoom
        // Pane layout strategy (plan §P4.5)
        case changeStrategy(LayoutStrategyKind)
        case cycleStrategy(forward: Bool)
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
        case runCommand(command: String, arguments: [String], options: CommandOptions)
        // Toggle broadcast-input for the active tab (sync typing across selected panes).
        case toggleBroadcastInput
        // Clear the multi-pane selection (and broadcast) for the active tab.
        case clearPaneSelection
        // Command palette (⌘P). Opens the fuzzy command panel in SSH scope
        // (the default). Prefixes inside the input switch to command / profile
        // / tab / session scopes.
        case showCommandPalette
        // Session palette (⌘R). Opens the palette pre-filled with `s ` so it
        // starts in session-switching scope.
        case showSessionPalette
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
            case .movePane(let dir):
                switch dir {
                case .left: "move_pane_left"
                case .right: "move_pane_right"
                case .up: "move_pane_up"
                case .down: "move_pane_down"
                }
            case .growPane: "grow_pane"
            case .shrinkPane: "shrink_pane"
            case .toggleZoom: "toggle_zoom"
            case .changeStrategy(let kind):
                "change_strategy_\(Self.strategyToken(for: kind))"
            case .cycleStrategy(let forward):
                forward ? "cycle_strategy_next" : "cycle_strategy_previous"
            case .newFloatingPane: "new_floating_pane"
            case .toggleOrCreateFloatingPane: "toggle_or_create_floating_pane"
            case .listRemoteSessions: "list_remote_sessions"
            case .newRemoteSession: "new_remote_session"
            case .showSessionPicker: "show_session_picker"
            case .detachSession: "detach_session"
            case .renameSession: "rename_session"
            case .runInPlace(let cmd, let args):
                Self.formatPrefixedAction(prefix: "run_in_place", command: cmd, arguments: args)
            case .runCommand(let cmd, let args, let opts):
                Self.formatPrefixedAction(prefix: "run_command", command: cmd, arguments: args, options: opts)
            case .toggleBroadcastInput: "toggle_broadcast_input"
            case .clearPaneSelection: "clear_pane_selection"
            case .showCommandPalette: "show_command_palette"
            case .showSessionPalette: "show_session_palette"
            case .unbind: "unbind"
            }
        }

        // MARK: - Helpers

        /// Snake-case token used in config strings (`change_strategy_<token>`).
        /// Internally, `LayoutStrategyKind` cases are camelCase; the token
        /// form exists only at the keybinding boundary.
        static func strategyToken(for kind: LayoutStrategyKind) -> String {
            switch kind {
            case .horizontal:  return "horizontal"
            case .vertical:    return "vertical"
            case .grid:        return "grid"
            case .masterStack: return "master_stack"
            case .fibonacci:   return "fibonacci"
            }
        }

        /// Reverse of `strategyToken(for:)`. Accepts both snake_case
        /// (`master_stack`) and the raw enum case name (`masterStack`) so
        /// user configs can use either style.
        static func strategyKind(fromToken token: String) -> LayoutStrategyKind? {
            switch token {
            case "horizontal":               return .horizontal
            case "vertical":                 return .vertical
            case "grid":                     return .grid
            case "master_stack", "masterStack": return .masterStack
            case "fibonacci":                return .fibonacci
            default:                         return nil
            }
        }

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
            case .movePane(let dir): .movePane(dir)
            case .growPane: .growPane
            case .shrinkPane: .shrinkPane
            case .toggleZoom: .toggleZoom
            case .changeStrategy(let kind): .changeStrategy(kind)
            case .cycleStrategy(let forward): .cycleStrategy(forward: forward)
            case .newFloatingPane: .newFloatingPane
            case .toggleOrCreateFloatingPane: .toggleOrCreateFloatingPane
            case .listRemoteSessions: .listRemoteSessions
            case .newRemoteSession: .newRemoteSession
            case .showSessionPicker: .showSessionPicker
            case .detachSession: .detachSession
            case .renameSession: .renameSession
            case .runInPlace(let cmd, let args): .runInPlace(command: cmd, arguments: args)
            case .runCommand(let cmd, let args, let opts): .runCommand(command: cmd, arguments: args, options: opts)
            case .toggleBroadcastInput: .toggleBroadcastInput
            case .clearPaneSelection: .clearPaneSelection
            case .showCommandPalette: .showCommandPalette
            case .showSessionPalette: .showSessionPalette
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
            case "move_pane_left": self = .movePane(.left)
            case "move_pane_right": self = .movePane(.right)
            case "move_pane_up": self = .movePane(.up)
            case "move_pane_down": self = .movePane(.down)
            case "grow_pane": self = .growPane
            case "shrink_pane": self = .shrinkPane
            case "toggle_zoom": self = .toggleZoom
            case "cycle_strategy_next": self = .cycleStrategy(forward: true)
            case "cycle_strategy_previous": self = .cycleStrategy(forward: false)
            case "new_floating_pane": self = .newFloatingPane
            case "toggle_or_create_floating_pane": self = .toggleOrCreateFloatingPane
            case "list_remote_sessions": self = .listRemoteSessions
            case "new_remote_session": self = .newRemoteSession
            case "show_session_picker": self = .showSessionPicker
            case "detach_session": self = .detachSession
            case "rename_session": self = .renameSession
            case "toggle_broadcast_input": self = .toggleBroadcastInput
            case "clear_pane_selection": self = .clearPaneSelection
            case "show_command_palette": self = .showCommandPalette
            case "show_session_palette": self = .showSessionPalette
            case "unbind": self = .unbind
            default:
                if rawValue.hasPrefix("goto_tab:"),
                   let n = Int(rawValue.dropFirst("goto_tab:".count)),
                   (1...9).contains(n) {
                    self = .gotoTab(n)
                    return
                }
                if rawValue.hasPrefix("change_strategy_"),
                   let kind = Self.strategyKind(
                       fromToken: String(rawValue.dropFirst("change_strategy_".count))
                   ) {
                    self = .changeStrategy(kind)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_in_place") {
                    self = .runInPlace(command: parsed.command, arguments: parsed.arguments)
                    return  // run_in_place does not use options (it always takes over the pane)
                }
                // "run_command" is the canonical name.
                // "run_local_command" → run_command with implicit [local].
                // "run_remote_command" → run_command with implicit [remote].
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_local_command") {
                    var opts = parsed.options
                    opts.setIfMissing("local")
                    self = .runCommand(command: parsed.command, arguments: parsed.arguments, options: opts)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_remote_command") {
                    var opts = parsed.options
                    opts.setIfMissing("remote")
                    self = .runCommand(command: parsed.command, arguments: parsed.arguments, options: opts)
                    return
                }
                if let parsed = Self.parsePrefixedAction(rawValue: rawValue, prefix: "run_command") {
                    var opts = parsed.options
                    // Default to [local] when neither local/remote/always_local is specified (backwards compat).
                    if !opts.runsLocal && !opts.runsRemote && !opts.alwaysLocal {
                        opts.setIfMissing("local")
                    }
                    self = .runCommand(command: parsed.command, arguments: parsed.arguments, options: opts)
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
        // Pane reordering — Ctrl+Cmd+Arrow (plan §P4.3)
        Keybinding(modifiers: [.command, .control], key: "left", action: .movePane(.left)),
        Keybinding(modifiers: [.command, .control], key: "right", action: .movePane(.right)),
        Keybinding(modifiers: [.command, .control], key: "up", action: .movePane(.up)),
        Keybinding(modifiers: [.command, .control], key: "down", action: .movePane(.down)),
        // Pane resize
        Keybinding(modifiers: .option, key: "=", action: .growPane),
        Keybinding(modifiers: .option, key: "-", action: .shrinkPane),
        // Pane zoom / monocle
        Keybinding(modifiers: [.command, .shift], key: "f", action: .toggleZoom),
        // Pane layout strategy — plan §P4.5
        Keybinding(modifiers: [.command, .shift, .option], key: "h",
                   action: .changeStrategy(.horizontal)),
        Keybinding(modifiers: [.command, .shift, .option], key: "v",
                   action: .changeStrategy(.vertical)),
        Keybinding(modifiers: [.command, .shift, .option], key: "g",
                   action: .changeStrategy(.grid)),
        Keybinding(modifiers: [.command, .shift, .option], key: "m",
                   action: .changeStrategy(.masterStack)),
        Keybinding(modifiers: .option, key: "]",
                   action: .cycleStrategy(forward: true)),
        Keybinding(modifiers: .option, key: "[",
                   action: .cycleStrategy(forward: false)),
        // Floating pane management
        Keybinding(modifiers: .option, key: "f", action: .toggleOrCreateFloatingPane),
        Keybinding(modifiers: .option, key: "n", action: .newFloatingPane),
        // In-place overlay
        Keybinding(modifiers: .option, key: "m", action: .runInPlace(command: "lazygit", arguments: [])),
        // Remote session management
        Keybinding(modifiers: .command, key: "y", action: .listRemoteSessions),
        Keybinding(modifiers: [.command, .shift], key: "i", action: .newRemoteSession),
        Keybinding(modifiers: .command, key: "r", action: .showSessionPalette),
        Keybinding(modifiers: [.command, .shift], key: "k", action: .detachSession),
        Keybinding(modifiers: [.command, .shift], key: "r", action: .renameSession),
        // Multi-pane selection
        Keybinding(modifiers: [.command, .option], key: ".", action: .clearPaneSelection),
        // Command palette
        Keybinding(modifiers: .command, key: "p", action: .showCommandPalette),
    ]

    /// Parse a keybinding string like "cmd+shift+t=new_tab".
    static func parse(_ string: String) throws -> Keybinding {
        // Find the '=' that separates key-combo from action.
        // Options like [x=1,y=2] contain '=' inside brackets, so we search
        // for the last '=' before the first '[' that appears in the action part.
        // The action part starts after the first '=', so look for '[' only after it.
        guard let firstEq = string.firstIndex(of: "=") else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }
        let afterFirstEq = string[string.index(after: firstEq)...]
        let bracketInAction = afterFirstEq.firstIndex(of: "[")
        let searchEnd = bracketInAction ?? string.endIndex
        let searchRange = string.startIndex..<searchEnd
        guard let eqIndex = string[searchRange].lastIndex(of: "=") else {
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
        // Arrow / function keys arrive with the `function` bit (and sometimes
        // `numericPad`) set in addition to the user-meaningful modifiers.
        // Strict equality vs. a binding declared as `[.command, .option]`
        // fails unless we narrow the mask to the flags configs care about.
        let eventMods = event.modifierFlags.intersection(.relevantFlags)
        let rawKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let eventKey = normalizedKey(from: rawKey)

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

    /// Maps macOS private-use function-key Unicode scalars back to the
    /// readable names used in keybinding configs. `charactersIgnoringModifiers`
    /// returns these scalars for keys that have no printable character
    /// (arrow keys, function keys, etc.).
    private static let namedSpecialKeys: [String: String] = [
        "\u{F700}": "up",
        "\u{F701}": "down",
        "\u{F702}": "left",
        "\u{F703}": "right",
    ]

    /// Normalize a raw event character (the `.lowercased()` output of
    /// `charactersIgnoringModifiers`) into the readable name used by keybinding
    /// configs. For ordinary characters this is the identity; for macOS
    /// private-use function-key scalars (arrow keys etc.) it returns the
    /// config-side alias (`"left"`, `"right"`, `"up"`, `"down"`).
    static func normalizedKey(from raw: String) -> String {
        namedSpecialKeys[raw] ?? raw
    }

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
