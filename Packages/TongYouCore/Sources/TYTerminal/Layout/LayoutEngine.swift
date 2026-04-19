import CoreGraphics
import Foundation

/// High-level pure-function API for pane tree mutations and layout.
///
/// Introduced in P3 of the auto-layout plan. Every operation takes a
/// `TerminalTab` and returns a new one (value semantics) — there is no
/// reference-typed engine instance. Side effects (PTY controllers, persistence,
/// focus state) stay in the caller (`SessionManager` / `ServerSessionManager`).
///
/// `LayoutEngine` owns three pieces of policy that used to live on the
/// `PaneNode` mutators:
/// - **Same-direction flattening** in `splitPane` (plan §3.7).
/// - Aggregation of `LayoutDispatch.solve` across a tree into `solveRects`.
/// - `sanitize` — re-run pruning / collapsing after an external write.
///
/// Low-level node operations (`PaneNode.split`, `.removePane`, `.updateRatio`)
/// remain as primitives that this engine composes on top of.
public enum LayoutEngine {

    /// Outcome of `closePane`. Callers that manage the tab list need to
    /// distinguish "the tree still has panes" from "the last pane was
    /// removed, close the tab".
    public enum CloseOutcome: Sendable {
        /// The pane was removed; the tab still has at least one pane left.
        /// `promotedFocusID` is the suggested new focus (depth-first first
        /// leaf of the updated tree).
        case closed(tab: TerminalTab, promotedFocusID: UUID)

        /// The pane was the only pane in the tab — the caller should close
        /// the tab itself.
        case emptiedTree
    }

    // MARK: - splitPane

    /// Split `targetPaneID` by inserting `newPane` next to it.
    ///
    /// When the target's direct parent container already lays out children in
    /// the requested direction, `newPane` is inserted as a sibling (flattening,
    /// per plan §3.7). Otherwise the target is wrapped in a new 2-child
    /// container — matching the BSP-compatible behavior the P2 `PaneNode.split`
    /// already implemented.
    ///
    /// Returns `nil` when `targetPaneID` is not a leaf in the tree.
    public static func splitPane(
        tab: TerminalTab,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: TerminalPane
    ) -> TerminalTab? {
        guard let newTree = splitNode(
            tab.paneTree,
            targetID: targetPaneID,
            direction: direction,
            newPane: newPane
        ) else { return nil }
        var newTab = tab
        newTab.paneTree = newTree
        return newTab
    }

    /// Recursively locate `targetID`. Flattening is decided at the parent
    /// container level: when a container sees one of its direct leaf children
    /// is the target and its own strategy matches the new split direction, it
    /// inserts `newPane` as a sibling instead of descending and wrapping.
    private static func splitNode(
        _ node: PaneNode,
        targetID: UUID,
        direction: SplitDirection,
        newPane: TerminalPane
    ) -> PaneNode? {
        let newStrategy = direction.strategy
        switch node {
        case .leaf(let pane):
            guard pane.id == targetID else { return nil }
            // Root-leaf or mismatched-parent case — wrap in a fresh
            // 2-child container with equal weights.
            return .container(Container(
                strategy: newStrategy,
                children: [.leaf(pane), .leaf(newPane)],
                weights: [1.0, 1.0]
            ))

        case .container(let c):
            // First pass: flatten if a direct leaf child matches and the
            // container's strategy aligns with the requested direction.
            if c.strategy == newStrategy {
                for (i, child) in c.children.enumerated() {
                    guard case .leaf(let pane) = child, pane.id == targetID else { continue }
                    var newChildren = c.children
                    var newWeights = c.weights
                    newChildren.insert(.leaf(newPane), at: i + 1)
                    newWeights.insert(1.0, at: i + 1)
                    return .container(Container(
                        id: c.id,
                        strategy: c.strategy,
                        children: newChildren,
                        weights: newWeights
                    ))
                }
            }
            // Otherwise recurse into children; a matching descendant will
            // either flatten against its own parent or be wrapped in a new
            // container at the leaf level.
            for (i, child) in c.children.enumerated() {
                guard let replaced = splitNode(
                    child,
                    targetID: targetID,
                    direction: direction,
                    newPane: newPane
                ) else { continue }
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

    // MARK: - closePane

    /// Remove `paneID` from the tab's tree. Parent containers that drop to a
    /// single child are collapsed; an empty tree is reported via
    /// `.emptiedTree` so the caller can close the tab.
    ///
    /// Returns `nil` when `paneID` is not in the tab's tree.
    public static func closePane(tab: TerminalTab, paneID: UUID) -> CloseOutcome? {
        guard tab.paneTree.contains(paneID: paneID) else { return nil }
        guard let newTree = tab.paneTree.removePane(id: paneID) else {
            return .emptiedTree
        }
        var newTab = tab
        newTab.paneTree = newTree
        let promoted = newTree.firstPane.id
        if newTab.focusedPaneID == paneID {
            newTab.focusedPaneID = promoted
        }
        return .closed(tab: newTab, promotedFocusID: promoted)
    }

    // MARK: - resizePane

    /// Apply a ratio-based resize to the container that directly owns
    /// `paneID`. Ratio semantics mirror `PaneNode.updateRatio` — meaningful
    /// primarily for 2-child containers; N-ary drag resizes flow through
    /// `updateActivePaneTree` instead.
    ///
    /// Returns `nil` when `paneID` is not in the tree.
    public static func resizePane(
        tab: TerminalTab,
        paneID: UUID,
        newRatio: CGFloat
    ) -> TerminalTab? {
        guard tab.paneTree.contains(paneID: paneID) else { return nil }
        var newTab = tab
        newTab.paneTree = tab.paneTree.updateRatio(for: paneID, newRatio: newRatio)
        return newTab
    }

    // MARK: - solveRects

    /// Map every leaf pane in the tab to its screen rect by recursively
    /// walking the tree and applying `LayoutDispatch.solve` at each
    /// container. Floating panes and zoom state are out of scope in P3 —
    /// `TerminalTab.zoomedPaneID` handling lands with P4.1.
    public static func solveRects(
        tab: TerminalTab,
        screenRect: Rect,
        minSize: Size = .defaultMin,
        dividerSize: Int = 0
    ) -> [UUID: Rect] {
        var result: [UUID: Rect] = [:]
        solveInto(
            node: tab.paneTree,
            rect: screenRect,
            minSize: minSize,
            dividerSize: dividerSize,
            into: &result
        )
        return result
    }

    private static func solveInto(
        node: PaneNode,
        rect: Rect,
        minSize: Size,
        dividerSize: Int,
        into result: inout [UUID: Rect]
    ) {
        switch node {
        case .leaf(let pane):
            result[pane.id] = rect
        case .container(let c):
            let solved = LayoutDispatch.solve(
                container: c,
                in: rect,
                minSize: minSize,
                dividerSize: dividerSize
            )
            for (child, childRect) in zip(c.children, solved.rects) {
                solveInto(
                    node: child,
                    rect: childRect,
                    minSize: minSize,
                    dividerSize: dividerSize,
                    into: &result
                )
            }
        }
    }

    // MARK: - sanitize

    /// Re-establish `Container` invariants on `tab.paneTree` without mutating
    /// weights: containers with no children are removed, single-child
    /// containers are replaced by their sole child. Used on the
    /// `updateActivePaneTree` path where external code (e.g. the drag handler)
    /// writes a tree back wholesale.
    ///
    /// Same-strategy adjacent-container merging (plan §五 rule 3) is
    /// intentionally not performed here — P3 relies on `splitPane`'s
    /// flattening to keep the tree well-shaped; rule 3 arrives with P4's
    /// `movePane`.
    public static func sanitize(tab: TerminalTab) -> TerminalTab {
        let cleaned = sanitize(node: tab.paneTree) ?? tab.paneTree
        guard cleaned != tab.paneTree else { return tab }
        var newTab = tab
        newTab.paneTree = cleaned
        return newTab
    }

    private static func sanitize(node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf:
            return node
        case .container(let c):
            var newChildren: [PaneNode] = []
            var newWeights: [CGFloat] = []
            for (i, child) in c.children.enumerated() {
                if let cleaned = sanitize(node: child) {
                    newChildren.append(cleaned)
                    newWeights.append(c.weights[i])
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            if newChildren == c.children { return node }
            return .container(Container(
                id: c.id,
                strategy: c.strategy,
                children: newChildren,
                weights: newWeights
            ))
        }
    }
}
