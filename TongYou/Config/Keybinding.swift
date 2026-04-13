import AppKit

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
        // Floating pane management
        case newFloatingPane
        case toggleOrCreateFloatingPane
        // Remote session management
        case listRemoteSessions
        case newRemoteSession
        case showSessionPicker
        case detachSession
        case renameSession
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
            case .newFloatingPane: "new_floating_pane"
            case .toggleOrCreateFloatingPane: "toggle_or_create_floating_pane"
            case .listRemoteSessions: "list_remote_sessions"
            case .newRemoteSession: "new_remote_session"
            case .showSessionPicker: "show_session_picker"
            case .detachSession: "detach_session"
            case .renameSession: "rename_session"
            case .unbind: "unbind"
            }
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
            case .newFloatingPane: .newFloatingPane
            case .toggleOrCreateFloatingPane: .toggleOrCreateFloatingPane
            case .listRemoteSessions: .listRemoteSessions
            case .newRemoteSession: .newRemoteSession
            case .showSessionPicker: .showSessionPicker
            case .detachSession: .detachSession
            case .renameSession: .renameSession
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
        Keybinding(modifiers: [.command, .shift], key: "left", action: .previousTab),
        Keybinding(modifiers: [.command, .shift], key: "right", action: .nextTab),
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
        // Floating pane management
        Keybinding(modifiers: .option, key: "f", action: .toggleOrCreateFloatingPane),
        Keybinding(modifiers: .option, key: "n", action: .newFloatingPane),
        // Remote session management
        Keybinding(modifiers: .command, key: "l", action: .listRemoteSessions),
        Keybinding(modifiers: [.command, .shift], key: "i", action: .newRemoteSession),
        Keybinding(modifiers: .command, key: "r", action: .showSessionPicker),
        Keybinding(modifiers: [.command, .shift], key: "k", action: .detachSession),
        Keybinding(modifiers: [.command, .shift], key: "r", action: .renameSession),
    ]

    /// Parse a keybinding string like "cmd+shift+t=new_tab".
    static func parse(_ string: String) throws -> Keybinding {
        guard let eqIndex = string.firstIndex(of: "=") else {
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

        guard let key = keyPart else {
            throw ConfigError.invalidValue(key: "keybind", value: string)
        }

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
        }
        return nil
    }
}

// MARK: - ModifierFlags Equatable for matching

extension NSEvent.ModifierFlags {
    /// The modifier flags we care about for keybinding matching.
    static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
}
