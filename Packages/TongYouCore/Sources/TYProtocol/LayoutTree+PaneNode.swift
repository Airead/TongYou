import CoreGraphics
import Foundation
import TYTerminal

/// Bidirectional conversion between `PaneNode` (TYTerminal) and `LayoutTree`
/// (TYProtocol). The wire side uses `PaneID` and `Float`; the model side uses
/// `UUID`, `TerminalPane`, and `CGFloat`.
extension LayoutTree {
    public init(from node: PaneNode) {
        switch node {
        case .leaf(let pane):
            self = .leaf(PaneID(pane.id))
        case .container(let c):
            self = .container(
                strategy: c.strategy,
                children: c.children.map(LayoutTree.init(from:)),
                weights: c.weights.map(Float.init)
            )
        }
    }
}

extension PaneNode {
    /// Build a `PaneNode` from a `LayoutTree`, resolving each leaf's pane
    /// data via the supplied closure. Returns nil if any leaf's pane cannot
    /// be resolved.
    public static func from(layout: LayoutTree, resolvePane: (PaneID) -> TerminalPane?) -> PaneNode? {
        switch layout {
        case .leaf(let paneID):
            guard let pane = resolvePane(paneID) else { return nil }
            return .leaf(pane)
        case .container(let strategy, let children, let weights):
            var nodes: [PaneNode] = []
            nodes.reserveCapacity(children.count)
            for child in children {
                guard let node = PaneNode.from(layout: child, resolvePane: resolvePane) else {
                    return nil
                }
                nodes.append(node)
            }
            return .container(Container(
                strategy: strategy,
                children: nodes,
                weights: weights.map { CGFloat($0) }
            ))
        }
    }
}
