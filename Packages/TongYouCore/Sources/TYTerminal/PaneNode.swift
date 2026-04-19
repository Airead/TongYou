import CoreGraphics
import Foundation

/// Direction for splitting a pane.
public enum SplitDirection: Equatable, Sendable, Codable {
    case horizontal  // top / bottom
    case vertical    // left / right

    /// Layout strategy that corresponds to this split orientation. A horizontal
    /// split stacks children top/bottom (strategy `.horizontal`); a vertical
    /// split lays them out left/right (strategy `.vertical`).
    public var strategy: LayoutStrategyKind {
        switch self {
        case .horizontal: return .horizontal
        case .vertical:   return .vertical
        }
    }
}

/// N-ary container node in the pane tree. Holds children under a given layout
/// strategy with parallel relative weights.
///
/// Invariant: `children.count == weights.count && children.count >= 1`.
/// The tree self-cleaning rule in the `LayoutEngine` (P3) collapses containers
/// whose `children.count < 2`; during P2 the mutation helpers on `PaneNode`
/// uphold that rule directly.
public struct Container: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var strategy: LayoutStrategyKind
    public var children: [PaneNode]
    public var weights: [CGFloat]

    public init(
        id: UUID = UUID(),
        strategy: LayoutStrategyKind,
        children: [PaneNode],
        weights: [CGFloat]
    ) {
        precondition(children.count == weights.count, "children.count must equal weights.count")
        precondition(!children.isEmpty, "Container must have at least one child")
        self.id = id
        self.strategy = strategy
        self.children = children
        self.weights = weights
    }
}

/// N-ary tree representing the pane layout within a tab.
///
/// - `.leaf`: A single terminal pane.
/// - `.container`: Multiple children arranged under a `LayoutStrategyKind`
///   (horizontal, vertical, grid, masterStack, fibonacci).
///
/// Introduced in P2 (auto-layout engine). During P2 every container produced
/// by user splits has exactly two children — the P3 `LayoutEngine` introduces
/// same-direction flattening so a row of 4 panes collapses into one container.
public indirect enum PaneNode: Equatable, Sendable {
    case leaf(TerminalPane)
    case container(Container)

    /// Stable identifier for this node.
    public var nodeID: UUID {
        switch self {
        case .leaf(let pane):       return pane.id
        case .container(let c):     return c.id
        }
    }

    // MARK: - Queries

    /// All panes in the tree, in depth-first (left-to-right) order.
    public var allPanes: [TerminalPane] {
        var result: [TerminalPane] = []
        collectPanes(into: &result)
        return result
    }

    private func collectPanes(into result: inout [TerminalPane]) {
        switch self {
        case .leaf(let pane):
            result.append(pane)
        case .container(let c):
            for child in c.children { child.collectPanes(into: &result) }
        }
    }

    /// All pane IDs in the tree.
    public var allPaneIDs: [UUID] {
        var result: [UUID] = []
        collectPaneIDs(into: &result)
        return result
    }

    private func collectPaneIDs(into result: inout [UUID]) {
        switch self {
        case .leaf(let pane):
            result.append(pane.id)
        case .container(let c):
            for child in c.children { child.collectPaneIDs(into: &result) }
        }
    }

    /// The pane count.
    public var paneCount: Int {
        switch self {
        case .leaf:
            return 1
        case .container(let c):
            return c.children.reduce(0) { $0 + $1.paneCount }
        }
    }

    /// Find a pane by ID.
    public func findPane(id: UUID) -> TerminalPane? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .container(let c):
            for child in c.children {
                if let found = child.findPane(id: id) { return found }
            }
            return nil
        }
    }

    /// Whether the tree contains a pane with the given ID.
    public func contains(paneID: UUID) -> Bool {
        findPane(id: paneID) != nil
    }

    /// The first leaf pane in depth-first order.
    public var firstPane: TerminalPane {
        switch self {
        case .leaf(let pane):
            return pane
        case .container(let c):
            return c.children[0].firstPane
        }
    }

    /// The root pane when the tree is a single leaf. Useful for single-pane tabs.
    public var rootPane: TerminalPane? {
        if case .leaf(let pane) = self { return pane }
        return nil
    }

    // MARK: - Mutations (return new tree)

    /// Split the leaf with the given ID in the given direction. The original
    /// pane becomes the first child of a new 2-child container; the `newPane`
    /// becomes the second child. Weights are initialized to `[1, 1]` (equal
    /// split). Returns nil if the ID is not found.
    ///
    /// P2 intentionally does not flatten same-direction splits into a single
    /// container — that behavior lands with the P3 `LayoutEngine`.
    public func split(paneID: UUID, direction: SplitDirection, newPane: TerminalPane) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return nil }
            return .container(Container(
                strategy: direction.strategy,
                children: [.leaf(pane), .leaf(newPane)],
                weights: [1.0, 1.0]
            ))
        case .container(let c):
            for (i, child) in c.children.enumerated() {
                guard let replaced = child.split(paneID: paneID, direction: direction, newPane: newPane) else { continue }
                var newChildren = c.children
                newChildren[i] = replaced
                return .container(Container(
                    id: c.id,
                    strategy: c.strategy,
                    children: newChildren,
                    weights: c.weights
                ))
            }
            return nil
        }
    }

    /// Remove a pane by ID. Parent containers are collapsed when they drop to a
    /// single remaining child, mirroring the BSP sibling-promotion rule.
    /// Returns nil when the entire tree consisted of just the removed leaf.
    public func removePane(id: UUID) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? nil : self
        case .container(let c):
            guard contains(paneID: id) else { return self }
            var newChildren: [PaneNode] = []
            var newWeights: [CGFloat] = []
            for (i, child) in c.children.enumerated() {
                if let updated = child.removePane(id: id) {
                    newChildren.append(updated)
                    newWeights.append(c.weights[i])
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }  // collapse
            return .container(Container(
                id: c.id,
                strategy: c.strategy,
                children: newChildren,
                weights: newWeights
            ))
        }
    }

    /// Update the parent container's weights so `paneID` occupies `newRatio`
    /// of its 2-child parent (BSP-compatible semantics). Only meaningful while
    /// containers are guaranteed 2-child (P2); with P3 flattening this helper
    /// will migrate into the `LayoutEngine`.
    public func updateRatio(for paneID: UUID, newRatio: CGFloat) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .container(let c):
            if c.children.count == 2 {
                for i in 0..<c.children.count {
                    guard case .leaf(let p) = c.children[i], p.id == paneID else { continue }
                    var newWeights = c.weights
                    newWeights[i] = newRatio
                    newWeights[1 - i] = 1.0 - newRatio
                    return .container(Container(
                        id: c.id,
                        strategy: c.strategy,
                        children: c.children,
                        weights: newWeights
                    ))
                }
            }
            var newChildren = c.children
            var changed = false
            for i in 0..<c.children.count {
                let updated = c.children[i].updateRatio(for: paneID, newRatio: newRatio)
                if updated != c.children[i] {
                    newChildren[i] = updated
                    changed = true
                }
            }
            guard changed else { return self }
            return .container(Container(
                id: c.id,
                strategy: c.strategy,
                children: newChildren,
                weights: c.weights
            ))
        }
    }

    /// Resize a pane by shifting its parent container's weights. A positive
    /// delta grows the pane; a negative delta shrinks it. The resulting ratio
    /// is clamped to `[0.1, 0.9]`. Returns nil when the pane is not inside
    /// any container (i.e. it is the tab's only pane).
    public func resizePane(id paneID: UUID, delta: CGFloat) -> PaneNode? {
        switch self {
        case .leaf:
            return nil
        case .container(let c):
            if c.children.count == 2 {
                for i in 0..<c.children.count {
                    guard case .leaf(let p) = c.children[i], p.id == paneID else { continue }
                    let sum = c.weights.reduce(0, +)
                    guard sum > 0 else { return nil }
                    let currentRatio = c.weights[i] / sum
                    let newRatio = min(max(currentRatio + delta, 0.1), 0.9)
                    var newWeights = c.weights
                    newWeights[i] = newRatio * sum
                    newWeights[1 - i] = (1.0 - newRatio) * sum
                    return .container(Container(
                        id: c.id,
                        strategy: c.strategy,
                        children: c.children,
                        weights: newWeights
                    ))
                }
            }
            for (i, child) in c.children.enumerated() {
                guard let updated = child.resizePane(id: paneID, delta: delta) else { continue }
                var newChildren = c.children
                newChildren[i] = updated
                return .container(Container(
                    id: c.id,
                    strategy: c.strategy,
                    children: newChildren,
                    weights: c.weights
                ))
            }
            return nil
        }
    }

    /// Replace a specific pane with a new subtree.
    public func replacingPane(id: UUID, with newNode: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? newNode : self
        case .container(let c):
            var newChildren = c.children
            for i in 0..<c.children.count {
                newChildren[i] = c.children[i].replacingPane(id: id, with: newNode)
            }
            return .container(Container(
                id: c.id,
                strategy: c.strategy,
                children: newChildren,
                weights: c.weights
            ))
        }
    }
}
