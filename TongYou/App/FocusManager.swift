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

    func moveFocus(direction: FocusDirection, in tree: PaneNode) {
        guard let currentID = focusedPaneID else {
            focusPane(id: tree.firstPane.id)
            return
        }

        if let nextID = tree.neighborOf(paneID: currentID, direction: direction) {
            focusPane(id: nextID)
        }
    }
}

/// Cardinal directions for focus navigation.
enum FocusDirection {
    case left, right, up, down
}

// MARK: - PaneNode Focus Navigation

extension PaneNode {

    /// Find the neighboring pane in the given direction. Returns nil if there
    /// is no neighbor in that direction.
    ///
    /// BSP-compatible navigation generalized to N-ary containers: build a path
    /// from root to the target, then walk up looking for a container whose
    /// strategy allows movement in the requested direction and where the step
    /// is not already at the edge.
    func neighborOf(paneID: UUID, direction: FocusDirection) -> UUID? {
        guard let path = pathTo(paneID: paneID) else { return nil }

        for step in path.reversed() {
            guard case .container(let c) = step.node else { continue }
            let idx = step.childIndex

            switch (c.strategy, direction) {
            case (.vertical, .left):
                if idx > 0 {
                    return nearestLeaf(in: c.children[idx - 1], preferring: .right)
                }
            case (.vertical, .right):
                if idx < c.children.count - 1 {
                    return nearestLeaf(in: c.children[idx + 1], preferring: .left)
                }
            case (.horizontal, .up):
                if idx > 0 {
                    return nearestLeaf(in: c.children[idx - 1], preferring: .down)
                }
            case (.horizontal, .down):
                if idx < c.children.count - 1 {
                    return nearestLeaf(in: c.children[idx + 1], preferring: .up)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Path from root to a specific pane.
    private func pathTo(paneID: UUID) -> [PathStep]? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? [] : nil
        case .container(let c):
            for (i, child) in c.children.enumerated() {
                if let subPath = child.pathTo(paneID: paneID) {
                    return [PathStep(node: self, childIndex: i)] + subPath
                }
            }
            return nil
        }
    }

    /// Return the nearest leaf pane on the side of the subtree that faces
    /// `direction`. For a container, recurse into the child whose edge aligns
    /// with the incoming direction; fall through to child 0 for axes that
    /// don't match the container's strategy.
    private func nearestLeaf(in node: PaneNode, preferring direction: FocusDirection) -> UUID {
        switch node {
        case .leaf(let pane):
            return pane.id
        case .container(let c):
            let idx: Int
            switch (c.strategy, direction) {
            case (.vertical, .left):   idx = 0
            case (.vertical, .right):  idx = c.children.count - 1
            case (.horizontal, .up):   idx = 0
            case (.horizontal, .down): idx = c.children.count - 1
            default:                   idx = 0
            }
            return nearestLeaf(in: c.children[idx], preferring: direction)
        }
    }
}

/// A step in the path from root to a target pane.
private struct PathStep {
    let node: PaneNode
    let childIndex: Int
}
