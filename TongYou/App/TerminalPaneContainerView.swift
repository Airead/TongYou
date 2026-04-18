import SwiftUI
import TYTerminal

/// NSViewRepresentable that manages a MetalView for a single terminal pane.
/// Creates the MetalView on first appearance and reuses it for subsequent displays.
struct TerminalPaneContainerView: NSViewRepresentable {

    let paneID: UUID
    let profileID: String
    let viewStore: MetalViewStore
    let initialWorkingDirectory: String?
    /// Shared configuration loader (global Config + profile live fields).
    let configLoader: ConfigLoader
    /// External controller for remote sessions. Nil for local sessions.
    let externalController: (any TerminalControlling)?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void
    let onFocused: () -> Void
    let onUserInteraction: (() -> Void)?
    var isProcessExited: (() -> Bool)?

    func makeNSView(context: Context) -> MetalView {
        if let existing = viewStore.view(for: paneID) {
            existing.paneID = paneID
            existing.profileID = profileID
            existing.configLoader = configLoader
            existing.onTabAction = onTabAction
            existing.onTitleChanged = onTitleChanged
            existing.onFocused = onFocused
            existing.onUserInteraction = onUserInteraction
            existing.isProcessExited = isProcessExited
            return existing
        }
        let view = MetalView()
        view.paneID = paneID
        view.profileID = profileID
        view.configLoader = configLoader
        view.initialWorkingDirectory = initialWorkingDirectory
        view.externalController = externalController
        view.onTabAction = onTabAction
        view.onTitleChanged = onTitleChanged
        view.onFocused = onFocused
        view.onUserInteraction = onUserInteraction
        view.isProcessExited = isProcessExited
        viewStore.store(view, for: paneID)
        return view
    }

    func updateNSView(_ nsView: MetalView, context: Context) {
        nsView.paneID = paneID
        nsView.profileID = profileID
        nsView.configLoader = configLoader
        nsView.onTabAction = onTabAction
        nsView.onTitleChanged = onTitleChanged
        nsView.onFocused = onFocused
        nsView.onUserInteraction = onUserInteraction
        nsView.isProcessExited = isProcessExited
        if nsView.externalController !== externalController {
            nsView.externalController = externalController
            if let external = externalController {
                nsView.bindController(external)
            }
        }
    }

    static func dismantleNSView(_ nsView: MetalView, coordinator: ()) {
        // Do NOT tear down here — the MetalView may be reused when switching tabs.
        // Tear down happens in TerminalWindowView.closeTab(at:).
    }
}
