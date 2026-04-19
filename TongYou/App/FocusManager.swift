import AppKit
import Foundation
import TYTerminal

/// Tracks which pane currently has keyboard focus within the window.
///
/// `focusPane(id:)` is the single entry point for all focus transitions
/// (keyboard shortcuts, mouse clicks, new-pane creation, automation).
/// It updates `focusedPaneID` (which drives the focus border) and also
/// promotes the matching `MetalView` to first responder so keyboard input
/// lands on the visible pane. Keeping both sides behind one call prevents
/// the two states from drifting out of sync.
@MainActor
@Observable
final class FocusManager {

    private(set) var focusedPaneID: UUID?

    /// History of focused pane IDs (most recent last). Includes both tree and floating panes.
    private(set) var focusHistory: [UUID] = []

    private let maxHistorySize = 64

    /// Provides access to MetalView instances for first-responder promotion.
    /// Held weakly because both objects are owned by `TerminalWindowView`.
    @ObservationIgnored private weak var viewStore: MetalViewStore?

    func attachViewStore(_ store: MetalViewStore) {
        viewStore = store
    }

    func focusPane(id: UUID) {
        if id != focusedPaneID {
            if let previous = focusedPaneID, previous != focusHistory.last {
                focusHistory.append(previous)
                if focusHistory.count > maxHistorySize {
                    focusHistory.removeFirst(focusHistory.count - maxHistorySize)
                }
            }
            focusedPaneID = id
        }
        promoteFirstResponder(paneID: id, retriesRemaining: 2)
    }

    /// Make the pane's MetalView the window first responder.
    ///
    /// When this runs immediately after a session/tab switch, SwiftUI may not
    /// have mounted the target pane's `MetalView` yet. In that case retry on
    /// the next run-loop tick so the view has a chance to register itself
    /// with the store during the intervening render pass.
    private func promoteFirstResponder(paneID: UUID, retriesRemaining: Int) {
        guard focusedPaneID == paneID else { return }
        if let view = viewStore?.view(for: paneID), let window = view.window {
            window.makeFirstResponder(view)
            return
        }
        guard retriesRemaining > 0 else { return }
        Task { @MainActor [weak self] in
            self?.promoteFirstResponder(paneID: paneID, retriesRemaining: retriesRemaining - 1)
        }
    }

    func clearFocus() {
        focusedPaneID = nil
    }

    func removeFromHistory(id: UUID) {
        focusHistory.removeAll { $0 == id }
    }

    func previousFocusedPane(existingIn paneIDs: Set<UUID>) -> UUID? {
        for id in focusHistory.reversed() {
            if paneIDs.contains(id) {
                return id
            }
        }
        return nil
    }

    /// Move focus from the current pane to its geometric neighbor in
    /// `direction` (plan §P4.2). Layout-based selection lives in
    /// `LayoutEngine.focusNeighbor`; this method only updates focus state.
    ///
    /// `screenRect` is the tab's content rect in terminal cells. When the
    /// caller does not yet have a real rect (plan §P3 step 7 has not landed
    /// for the render layer), a sufficiently large canvas works — the
    /// neighbor algorithm depends only on relative geometry.
    func moveFocus(direction: FocusDirection, in tab: TerminalTab, screenRect: Rect) {
        guard let currentID = focusedPaneID else {
            focusPane(id: tab.paneTree.firstPane.id)
            return
        }

        if let nextID = LayoutEngine.focusNeighbor(
            tab: tab,
            screenRect: screenRect,
            from: currentID,
            direction: direction
        ) {
            focusPane(id: nextID)
        }
    }
}
