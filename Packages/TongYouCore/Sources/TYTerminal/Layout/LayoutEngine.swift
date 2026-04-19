import CoreGraphics
import Foundation

/// High-level pure-function API for pane tree mutations and layout.
///
/// Introduced in P3 of the auto-layout plan. Every operation is a pure
/// function — there is no reference-typed engine instance. Side effects
/// (PTY controllers, persistence, focus state) stay in the caller.
///
/// The engine owns three pieces of policy previously spread across the
/// `PaneNode` mutators:
/// - **Same-direction flattening** in `splitPane` (plan §3.7).
/// - Aggregation of `LayoutDispatch.solve` across a tree into `solveRects`.
/// - `sanitize` — re-run pruning / collapsing after an external write.
///
/// Two entry styles are provided:
/// - **Tree-level** (`splitPane(tree:…)`, `closePane(tree:…)`, …) operates on
///   a `PaneNode`. Used by the server side (`ServerSessionManager`) whose
///   tab type is independent of `TerminalTab`.
/// - **Tab-level** (`splitPane(tab:…)`, …) wraps the tree-level API and also
///   propagates cross-field state on `TerminalTab` (e.g. resetting
///   `focusedPaneID` when the focused pane is closed).
///
/// Low-level node operations on `PaneNode` (`split`, `removePane`,
/// `updateRatio`) remain as primitives that these entries compose on top of.
public enum LayoutEngine {

    /// Tab-level close outcome. Callers that manage the tab list need to
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

    /// Tree-level close outcome — the `PaneNode`-layer counterpart to
    /// `CloseOutcome`, returned by `closePane(tree:…)`.
    public enum TreeCloseOutcome: Sendable {
        case closed(newTree: PaneNode, promotedFocusID: UUID)
        case emptiedTree
    }

    // MARK: - splitPane (tree-level)

    /// Split `targetPaneID` by inserting `newPane` next to it.
    ///
    /// When the target's direct parent container already lays out children in
    /// the requested direction, `newPane` is inserted as a sibling (flattening,
    /// per plan §3.7). Otherwise the target leaf is wrapped in a new 2-child
    /// container — matching the BSP-compatible behavior `PaneNode.split` had
    /// in P2.
    ///
    /// Returns `nil` when `targetPaneID` is not a leaf in `tree`.
    public static func splitPane(
        tree: PaneNode,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: TerminalPane
    ) -> PaneNode? {
        splitNode(
            tree,
            targetID: targetPaneID,
            direction: direction,
            newPane: newPane
        )
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

    // MARK: - closePane (tree-level)

    /// Remove `paneID` from `tree`. Parent containers that drop to a single
    /// child are collapsed; an empty tree is reported via `.emptiedTree` so
    /// the caller can close the tab.
    ///
    /// Returns `nil` when `paneID` is not in `tree`.
    public static func closePane(tree: PaneNode, paneID: UUID) -> TreeCloseOutcome? {
        guard tree.contains(paneID: paneID) else { return nil }
        guard let newTree = tree.removePane(id: paneID) else {
            return .emptiedTree
        }
        return .closed(newTree: newTree, promotedFocusID: newTree.firstPane.id)
    }

    // MARK: - resizePane (tree-level)

    /// Apply a ratio-based resize to the container that directly owns
    /// `paneID`. Ratio semantics mirror `PaneNode.updateRatio` — meaningful
    /// primarily for 2-child containers; N-ary drag resizes flow through
    /// `sanitize(tree:)` (via `updateActivePaneTree`) instead.
    ///
    /// Returns `nil` when `paneID` is not in `tree`.
    public static func resizePane(
        tree: PaneNode,
        paneID: UUID,
        newRatio: CGFloat
    ) -> PaneNode? {
        guard tree.contains(paneID: paneID) else { return nil }
        return tree.updateRatio(for: paneID, newRatio: newRatio)
    }

    // MARK: - sanitize (tree-level)

    /// Re-establish `Container` invariants without mutating weights:
    /// containers with no children are removed, single-child containers are
    /// replaced by their sole child. Used on the `updateActivePaneTree` path
    /// where external code (e.g. the drag handler) writes a tree back
    /// wholesale.
    ///
    /// Same-strategy adjacent-container merging (plan §五 rule 3) is
    /// intentionally not performed here — P3 relies on `splitPane`'s
    /// flattening to keep the tree well-shaped; rule 3 arrives with P4's
    /// `movePane`.
    public static func sanitize(tree: PaneNode) -> PaneNode {
        cleaned(node: tree) ?? tree
    }

    private static func cleaned(node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf:
            return node
        case .container(let c):
            var newChildren: [PaneNode] = []
            var newWeights: [CGFloat] = []
            for (i, child) in c.children.enumerated() {
                if let child = cleaned(node: child) {
                    newChildren.append(child)
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

    // MARK: - Tab-level wrappers

    /// `TerminalTab` convenience over `splitPane(tree:…)`. Leaves every non-
    /// tree field of the tab untouched.
    public static func splitPane(
        tab: TerminalTab,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: TerminalPane
    ) -> TerminalTab? {
        guard let newTree = splitPane(
            tree: tab.paneTree,
            targetPaneID: targetPaneID,
            direction: direction,
            newPane: newPane
        ) else { return nil }
        var next = tab
        next.paneTree = newTree
        return next
    }

    /// `TerminalTab` convenience over `closePane(tree:…)`. Additionally
    /// keeps `focusedPaneID` consistent: if the tab was focused on the
    /// closed pane, it is advanced to the promoted pane. Exits zoom when
    /// the zoomed pane is the one being closed (plan §P4.1).
    public static func closePane(tab: TerminalTab, paneID: UUID) -> CloseOutcome? {
        guard let outcome = closePane(tree: tab.paneTree, paneID: paneID) else { return nil }
        switch outcome {
        case .emptiedTree:
            return .emptiedTree
        case .closed(let newTree, let promoted):
            var next = tab
            next.paneTree = newTree
            if next.focusedPaneID == paneID {
                next.focusedPaneID = promoted
            }
            if next.zoomedPaneID == paneID {
                next.zoomedPaneID = nil
            }
            return .closed(tab: next, promotedFocusID: promoted)
        }
    }

    /// `TerminalTab` convenience over `resizePane(tree:…)`.
    public static func resizePane(
        tab: TerminalTab,
        paneID: UUID,
        newRatio: CGFloat
    ) -> TerminalTab? {
        guard let newTree = resizePane(
            tree: tab.paneTree,
            paneID: paneID,
            newRatio: newRatio
        ) else { return nil }
        var next = tab
        next.paneTree = newTree
        return next
    }

    /// `TerminalTab` convenience over `sanitize(tree:…)`. Also drops
    /// `zoomedPaneID` if the referenced pane has vanished from the tree
    /// (e.g. external tree write deleted it).
    public static func sanitize(tab: TerminalTab) -> TerminalTab {
        let cleaned = sanitize(tree: tab.paneTree)
        let staleZoom = tab.zoomedPaneID.map { !cleaned.contains(paneID: $0) } ?? false
        guard cleaned != tab.paneTree || staleZoom else { return tab }
        var next = tab
        next.paneTree = cleaned
        if staleZoom { next.zoomedPaneID = nil }
        return next
    }

    // MARK: - toggleZoom (tab-level)

    /// Toggle the zoom / monocle state for `paneID` in `tab` (plan §P4.1).
    /// When the pane is already zoomed, clears the flag; otherwise sets it.
    /// Returns `nil` when `paneID` is not in `tab.paneTree`.
    public static func toggleZoom(tab: TerminalTab, paneID: UUID) -> TerminalTab? {
        guard tab.paneTree.contains(paneID: paneID) else { return nil }
        var next = tab
        next.zoomedPaneID = (tab.zoomedPaneID == paneID) ? nil : paneID
        return next
    }

    // MARK: - focusNeighbor

    /// Find the pane in `tab` that should receive focus when moving from
    /// `paneID` in `direction` (plan §P4.2).
    ///
    /// Geometric algorithm: solve the tree into rects, then pick the pane
    /// whose edge in the requested direction is flush against the source's
    /// opposing edge and whose perpendicular-axis overlap with the source is
    /// greatest. Corner-only touching (overlap == 0) does not count.
    ///
    /// Uses `dividerSize: 0` so adjacent rects share exact edges, making the
    /// flush-edge test a simple equality check.
    ///
    /// Returns `nil` when:
    /// - `paneID` is not in `tab.paneTree` (or is shadowed by `zoomedPaneID`)
    /// - no pane sits flush in the requested direction with positive overlap
    public static func focusNeighbor(
        tab: TerminalTab,
        screenRect: Rect,
        from paneID: UUID,
        direction: FocusDirection
    ) -> UUID? {
        let rects = solveRects(tab: tab, screenRect: screenRect, dividerSize: 0)
        guard let origin = rects[paneID] else { return nil }

        var best: (id: UUID, overlap: Int)?
        for (candidateID, rect) in rects where candidateID != paneID {
            guard let overlap = neighborOverlap(
                origin: origin,
                candidate: rect,
                direction: direction
            ) else { continue }
            if let current = best, current.overlap >= overlap { continue }
            best = (candidateID, overlap)
        }
        return best?.id
    }

    private static func neighborOverlap(
        origin: Rect,
        candidate: Rect,
        direction: FocusDirection
    ) -> Int? {
        switch direction {
        case .right:
            guard candidate.x == origin.x + origin.width else { return nil }
            return positiveOverlap(
                a0: origin.y, a1: origin.y + origin.height,
                b0: candidate.y, b1: candidate.y + candidate.height
            )
        case .left:
            guard candidate.x + candidate.width == origin.x else { return nil }
            return positiveOverlap(
                a0: origin.y, a1: origin.y + origin.height,
                b0: candidate.y, b1: candidate.y + candidate.height
            )
        case .down:
            guard candidate.y == origin.y + origin.height else { return nil }
            return positiveOverlap(
                a0: origin.x, a1: origin.x + origin.width,
                b0: candidate.x, b1: candidate.x + candidate.width
            )
        case .up:
            guard candidate.y + candidate.height == origin.y else { return nil }
            return positiveOverlap(
                a0: origin.x, a1: origin.x + origin.width,
                b0: candidate.x, b1: candidate.x + candidate.width
            )
        }
    }

    private static func positiveOverlap(a0: Int, a1: Int, b0: Int, b1: Int) -> Int? {
        let v = min(a1, b1) - max(a0, b0)
        return v > 0 ? v : nil
    }

    // MARK: - solveRects

    /// Map every leaf pane in the tab to its screen rect by recursively
    /// walking the tree and applying `LayoutDispatch.solve` at each
    /// container. Floating panes are out of scope.
    ///
    /// When `tab.zoomedPaneID` is set and still points to a pane in the
    /// tree, only that pane is returned — filling the entire `screenRect`
    /// (plan §P4.1). A stale `zoomedPaneID` is ignored.
    public static func solveRects(
        tab: TerminalTab,
        screenRect: Rect,
        minSize: Size = .defaultMin,
        dividerSize: Int = 0
    ) -> [UUID: Rect] {
        if let zoomed = tab.zoomedPaneID, tab.paneTree.contains(paneID: zoomed) {
            return [zoomed: screenRect]
        }
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
}

/// Cardinal directions for focus navigation. Consumed by
/// `LayoutEngine.focusNeighbor`.
public enum FocusDirection: Sendable {
    case left, right, up, down
}
