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

    /// The set of commands allowed to activate the window (app-level).
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
        let allowed = isFocusWhitelisted(command)
        GUILog.debug(
            "activateIfAllowed command=\(command) allowed=\(allowed)",
            category: .session
        )
        guard allowed else { return }
        GUILog.debug(
            "NSApp.activate firing for \(command); stack=\n\(Thread.callStackSymbols.prefix(12).joined(separator: "\n"))",
            category: .session
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - View-level focus policy (Phase 7 extension)
    //
    // Separate from the app-level activation above: `shouldTakeViewFocus`
    // controls *within-app* focus transitions — switching active session,
    // active tab, focusing a newly created pane. Automation commands that
    // only mutate content (session.create, tab.create, pane.split,
    // floatPane.create) should leave the user's current view alone unless
    // the caller explicitly opts in via `viewFocus: true`.

    /// The automation command currently being handled on the main actor,
    /// or nil if the current mutation came from a user action. Set only by
    /// `withAutomationRequest(command:viewFocus:_:)`.
    private(set) static var currentCommand: AutomationCommand?

    /// Whether the currently handled automation command asked to take
    /// view-level focus. Meaningful only when `currentCommand != nil`.
    private(set) static var requestedViewFocus: Bool = false

    /// True while an automation command is being handled on the main actor.
    static var isAutomationRequest: Bool { currentCommand != nil }

    /// Run `body` with the automation context flags set. Restores previous
    /// flags on exit so nested calls behave correctly.
    static func withAutomationRequest<T>(
        command: AutomationCommand,
        viewFocus: Bool = false,
        _ body: () -> T
    ) -> T {
        let prevCommand = currentCommand
        let prevViewFocus = requestedViewFocus
        currentCommand = command
        requestedViewFocus = viewFocus
        defer {
            currentCommand = prevCommand
            requestedViewFocus = prevViewFocus
        }
        return body()
    }

    /// Called by SessionManager / automation handlers at "auto-switch
    /// active" points (e.g. setting `activeSessionIndex` right after
    /// `sessions.append`) to decide whether the switch should happen.
    /// - User actions (no automation in flight): always true.
    /// - Automation commands whose purpose *is* to move focus
    ///   (pane.focus, floatPane.focus, tab.select): always true.
    /// - Other automation commands: true only when `viewFocus: true`
    ///   was passed.
    static func shouldTakeViewFocus() -> Bool {
        guard let cmd = currentCommand else { return true }
        switch cmd {
        case .paneFocus, .floatPaneFocus, .tabSelect:
            return true
        default:
            return requestedViewFocus
        }
    }
}
