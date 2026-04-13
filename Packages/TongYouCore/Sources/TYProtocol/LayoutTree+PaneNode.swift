import Foundation
import TYTerminal

/// Convert PaneNode (TYTerminal) to LayoutTree (TYProtocol).
extension LayoutTree {
    public init(from node: PaneNode) {
        switch node {
        case .leaf(let pane):
            self = .leaf(PaneID(pane.id))
        case .split(let direction, let ratio, let first, let second):
            self = .split(
                direction: direction,
                ratio: Float(ratio),
                first: LayoutTree(from: first),
                second: LayoutTree(from: second)
            )
        }
    }
}
