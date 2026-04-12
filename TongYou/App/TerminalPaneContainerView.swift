import SwiftUI

/// NSViewRepresentable that manages a MetalView for a single terminal pane.
/// Creates the MetalView on first appearance and reuses it for subsequent displays.
struct TerminalPaneContainerView: NSViewRepresentable {

    let paneID: UUID
    let viewStore: MetalViewStore
    let initialWorkingDirectory: String?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void

    func makeNSView(context: Context) -> MetalView {
        if let existing = viewStore.view(for: paneID) {
            existing.onTabAction = onTabAction
            existing.onTitleChanged = onTitleChanged
            return existing
        }
        let view = MetalView()
        view.initialWorkingDirectory = initialWorkingDirectory
        view.onTabAction = onTabAction
        view.onTitleChanged = onTitleChanged
        viewStore.store(view, for: paneID)
        return view
    }

    func updateNSView(_ nsView: MetalView, context: Context) {
        nsView.onTabAction = onTabAction
        nsView.onTitleChanged = onTitleChanged
    }

    static func dismantleNSView(_ nsView: MetalView, coordinator: ()) {
        // Do NOT tear down here — the MetalView may be reused when switching tabs.
        // Tear down happens in TerminalWindowView.closeTab(at:).
    }
}
