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

    /// Find the neighboring pane in the given direction.
    /// Returns nil if there is no neighbor in that direction.
    func neighborOf(paneID: UUID, direction: FocusDirection) -> UUID? {
        // Build a path from root to the target pane, then walk up to find
        // the first split whose direction matches the requested movement.
        guard let path = pathTo(paneID: paneID) else { return nil }

        // Walk up the path looking for a split we can cross.
        for i in stride(from: path.count - 1, through: 0, by: -1) {
            let step = path[i]
            guard case .split(let dir, _, let child1, let child2) = step.node else { continue }

            switch (dir, direction, step.isFirst) {
            // Vertical split (left | right): can move left/right between children.
            case (.vertical, .left, false):
                return nearestLeaf(in: child1, preferring: .right)
            case (.vertical, .right, true):
                return nearestLeaf(in: child2, preferring: .left)
            // Horizontal split (top | bottom): can move up/down between children.
            case (.horizontal, .up, false):
                return nearestLeaf(in: child1, preferring: .down)
            case (.horizontal, .down, true):
                return nearestLeaf(in: child2, preferring: .up)
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
        case .split(_, _, let child1, let child2):
            if let subPath = child1.pathTo(paneID: paneID) {
                return [PathStep(node: self, isFirst: true)] + subPath
            }
            if let subPath = child2.pathTo(paneID: paneID) {
                return [PathStep(node: self, isFirst: false)] + subPath
            }
            return nil
        }
    }

    /// Get the nearest leaf pane on the preferred side of a subtree.
    private func nearestLeaf(in node: PaneNode, preferring direction: FocusDirection) -> UUID {
        switch node {
        case .leaf(let pane):
            return pane.id
        case .split(let dir, _, let child1, let child2):
            switch (dir, direction) {
            case (.vertical, .left): return nearestLeaf(in: child1, preferring: direction)
            case (.vertical, .right): return nearestLeaf(in: child2, preferring: direction)
            case (.horizontal, .up): return nearestLeaf(in: child1, preferring: direction)
            case (.horizontal, .down): return nearestLeaf(in: child2, preferring: direction)
            default: return nearestLeaf(in: child1, preferring: direction)
            }
        }
    }
}

/// A step in the path from root to a target pane.
private struct PathStep {
    let node: PaneNode
    let isFirst: Bool  // Whether the target is in the first child.
}
