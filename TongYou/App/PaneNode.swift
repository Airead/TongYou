import Foundation

/// Direction for splitting a pane.
enum SplitDirection: Equatable {
    case horizontal  // top / bottom
    case vertical    // left / right
}

/// Binary tree representing the pane layout within a tab.
///
/// - `.leaf`: A single terminal pane.
/// - `.split`: Two children separated by a divider.
indirect enum PaneNode: Equatable {
    case leaf(TerminalPane)
    case split(direction: SplitDirection, ratio: CGFloat, first: PaneNode, second: PaneNode)

    // MARK: - Queries

    /// All panes in the tree, in depth-first (left-to-right) order.
    var allPanes: [TerminalPane] {
        var result: [TerminalPane] = []
        collectPanes(into: &result)
        return result
    }

    private func collectPanes(into result: inout [TerminalPane]) {
        switch self {
        case .leaf(let pane):
            result.append(pane)
        case .split(_, _, let first, let second):
            first.collectPanes(into: &result)
            second.collectPanes(into: &result)
        }
    }

    /// All pane IDs in the tree.
    var allPaneIDs: [UUID] {
        var result: [UUID] = []
        collectPaneIDs(into: &result)
        return result
    }

    private func collectPaneIDs(into result: inout [UUID]) {
        switch self {
        case .leaf(let pane):
            result.append(pane.id)
        case .split(_, _, let first, let second):
            first.collectPaneIDs(into: &result)
            second.collectPaneIDs(into: &result)
        }
    }

    /// The pane count.
    var paneCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, let first, let second):
            return first.paneCount + second.paneCount
        }
    }

    /// Find a pane by ID.
    func findPane(id: UUID) -> TerminalPane? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, _, let first, let second):
            return first.findPane(id: id) ?? second.findPane(id: id)
        }
    }

    /// Whether the tree contains a pane with the given ID.
    func contains(paneID: UUID) -> Bool {
        findPane(id: paneID) != nil
    }

    /// The first leaf pane in depth-first order.
    var firstPane: TerminalPane {
        switch self {
        case .leaf(let pane):
            return pane
        case .split(_, _, let first, _):
            return first.firstPane
        }
    }

    /// The root pane when the tree is a single leaf. Useful for single-pane tabs.
    var rootPane: TerminalPane? {
        if case .leaf(let pane) = self { return pane }
        return nil
    }

    // MARK: - Mutations (return new tree)

    /// Replace the leaf with the given ID by splitting it in the given direction.
    /// The original pane becomes the first child; a new pane becomes the second child.
    /// Returns the new tree and the newly created pane, or nil if the ID was not found.
    func split(paneID: UUID, direction: SplitDirection, newPane: TerminalPane) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return nil }
            return .split(
                direction: direction,
                ratio: 0.5,
                first: .leaf(pane),
                second: .leaf(newPane)
            )
        case .split(let dir, let ratio, let first, let second):
            if let newFirst = first.split(paneID: paneID, direction: direction, newPane: newPane) {
                return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
            }
            if let newSecond = second.split(paneID: paneID, direction: direction, newPane: newPane) {
                return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
            }
            return nil
        }
    }

    /// Remove a pane by ID. The sibling of the removed pane is promoted.
    /// Returns nil if the removed pane is the only leaf (tree becomes empty).
    func removePane(id: UUID) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            // Removing the only leaf — tree becomes empty.
            return pane.id == id ? nil : self
        case .split(let dir, let ratio, let first, let second):
            // Check if the target is an immediate child.
            if case .leaf(let pane) = first, pane.id == id {
                return second  // Promote sibling.
            }
            if case .leaf(let pane) = second, pane.id == id {
                return first   // Promote sibling.
            }
            // Recurse into children.
            if let newFirst = first.removePane(id: id), newFirst != first {
                return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
            }
            if let newSecond = second.removePane(id: id), newSecond != second {
                return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
            }
            return self  // ID not found; return unchanged.
        }
    }

    /// Update the split ratio at the node that directly contains the given pane ID as a leaf child.
    func updateRatio(for paneID: UUID, newRatio: CGFloat) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let dir, let ratio, let first, let second):
            // If the pane is a direct leaf child of this split, update this node's ratio.
            switch (first, second) {
            case (.leaf(let p), _) where p.id == paneID,
                 (_, .leaf(let p)) where p.id == paneID:
                return .split(direction: dir, ratio: newRatio, first: first, second: second)
            default:
                return .split(
                    direction: dir,
                    ratio: ratio,
                    first: first.updateRatio(for: paneID, newRatio: newRatio),
                    second: second.updateRatio(for: paneID, newRatio: newRatio)
                )
            }
        }
    }

    /// Replace a specific pane with a new subtree.
    func replacingPane(id: UUID, with newNode: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? newNode : self
        case .split(let dir, let ratio, let first, let second):
            return .split(
                direction: dir,
                ratio: ratio,
                first: first.replacingPane(id: id, with: newNode),
                second: second.replacingPane(id: id, with: newNode)
            )
        }
    }
}
