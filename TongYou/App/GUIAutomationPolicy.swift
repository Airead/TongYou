import AppKit

/// Phase 7 focus policy.
///
/// Every automation command executed by `GUIAutomationService` corresponds
/// to an `AutomationCommand` case. Only commands whose explicit purpose is
/// to direct user attention (`paneFocus`, `floatPaneFocus`, `windowFocus`)
/// are allowed to bring the GUI window to the foreground; all others must
/// silently leave window activation alone.
///
/// The check is centralized here rather than scattered across
/// `SessionManager` / `FocusManager` because — at present — `NSApp.activate`
/// is only reached through `GUIAutomationService.activateApp()`. Funnelling
/// activation through `activateIfAllowed(command:)` keeps the rule in one
/// place and turns future violations into a compile-time reminder (new
/// commands must declare their policy by passing a case).
enum AutomationCommand {
    case serverPing
    case sessionList
    case sessionCreate
    case sessionClose
    case sessionAttach
    case sessionDetach
    case paneSendText
    case paneSendKey
    case tabCreate
    case tabSelect
    case tabClose
    case paneSplit
    case paneFocus
    case paneClose
    case paneResize
    case floatPaneCreate
    case floatPaneFocus
    case floatPaneClose
    case floatPanePin
    case floatPaneMove
    case windowFocus
}

@MainActor
enum GUIAutomationPolicy {

    /// The set of commands allowed to activate the window.
    static func isFocusWhitelisted(_ command: AutomationCommand) -> Bool {
        switch command {
        case .paneFocus, .floatPaneFocus, .windowFocus:
            return true
        default:
            return false
        }
    }

    /// Bring the GUI to the foreground iff `command` is focus-whitelisted.
    /// Non-whitelisted commands return silently so automation requests from
    /// a backgrounded context never steal focus.
    static func activateIfAllowed(command: AutomationCommand) {
        guard isFocusWhitelisted(command) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
