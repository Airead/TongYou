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

    // MARK: - swapPanes (tree-level)

    /// Swap the TerminalPane payloads between two leaves in `tree`. Tree
    /// topology and container identity are untouched — only the pane that
    /// sits at each leaf changes. `a == b` is a no-op.
    ///
    /// Returns `nil` when either pane is not in the tree.
    public static func swapPanes(tree: PaneNode, a: UUID, b: UUID) -> PaneNode? {
        if a == b { return tree }
        guard let paneA = tree.findPane(id: a),
              let paneB = tree.findPane(id: b) else { return nil }
        return swapLeaves(node: tree, idA: a, paneA: paneA, idB: b, paneB: paneB)
    }

    private static func swapLeaves(
        node: PaneNode,
        idA: UUID, paneA: TerminalPane,
        idB: UUID, paneB: TerminalPane
    ) -> PaneNode {
        switch node {
        case .leaf(let pane):
            if pane.id == idA { return .leaf(paneB) }
            if pane.id == idB { return .leaf(paneA) }
            return node
        case .container(let c):
            let newChildren = c.children.map {
                swapLeaves(node: $0, idA: idA, paneA: paneA, idB: idB, paneB: paneB)
            }
            if newChildren == c.children { return node }
            return .container(Container(
                id: c.id,
                strategy: c.strategy,
                children: newChildren,
                weights: c.weights
            ))
        }
    }

    // MARK: - movePane (tree-level)

    /// Remove `sourceID` from its current container and reinsert it on the
    /// requested side of `targetID` (plan §P4.3). The removal path runs
    /// through `sanitize` so pruning, collapsing, and rule-3 merging apply;
    /// insertion flattens into `targetID`'s parent when the container
    /// strategy already matches the requested axis.
    ///
    /// Returns `nil` when:
    /// - `sourceID == targetID`
    /// - either pane is not in `tree`
    /// - removal would empty the tree (should be unreachable since the
    ///   target pane guarantees at least one remaining leaf)
    public static func movePane(
        tree: PaneNode,
        sourceID: UUID,
        targetID: UUID,
        side: FocusDirection
    ) -> PaneNode? {
        guard sourceID != targetID else { return nil }
        guard let sourcePane = tree.findPane(id: sourceID),
              tree.contains(paneID: targetID) else { return nil }
        guard let removed = tree.removePane(id: sourceID) else { return nil }
        let cleanedTree = sanitize(tree: removed)
        guard let inserted = insertAdjacent(
            node: cleanedTree,
            targetID: targetID,
            side: side,
            newPane: sourcePane
        ) else { return nil }
        return sanitize(tree: inserted)
    }

    private static func insertAdjacent(
        node: PaneNode,
        targetID: UUID,
        side: FocusDirection,
        newPane: TerminalPane
    ) -> PaneNode? {
        let newStrategy: LayoutStrategyKind
        switch side {
        case .left, .right: newStrategy = .vertical
        case .up, .down:    newStrategy = .horizontal
        }
        let insertAfter = (side == .right || side == .down)
        return insertAdjacentRecurse(
            node: node,
            targetID: targetID,
            newStrategy: newStrategy,
            insertAfter: insertAfter,
            newPane: newPane
        )
    }

    private static func insertAdjacentRecurse(
        node: PaneNode,
        targetID: UUID,
        newStrategy: LayoutStrategyKind,
        insertAfter: Bool,
        newPane: TerminalPane
    ) -> PaneNode? {
        switch node {
        case .leaf(let pane):
            guard pane.id == targetID else { return nil }
            let children: [PaneNode] = insertAfter
                ? [.leaf(pane), .leaf(newPane)]
                : [.leaf(newPane), .leaf(pane)]
            return .container(Container(
                strategy: newStrategy,
                children: children,
                weights: [1.0, 1.0]
            ))
        case .container(let c):
            if c.strategy == newStrategy {
                for (i, child) in c.children.enumerated() {
                    guard case .leaf(let pane) = child, pane.id == targetID else { continue }
                    var newChildren = c.children
                    var newWeights = c.weights
                    let insertIdx = insertAfter ? i + 1 : i
                    newChildren.insert(.leaf(newPane), at: insertIdx)
                    newWeights.insert(1.0, at: insertIdx)
                    return .container(Container(
                        id: c.id,
                        strategy: c.strategy,
                        children: newChildren,
                        weights: newWeights
                    ))
                }
            }
            for (i, child) in c.children.enumerated() {
                guard let replaced = insertAdjacentRecurse(
                    node: child,
                    targetID: targetID,
                    newStrategy: newStrategy,
                    insertAfter: insertAfter,
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

    // MARK: - changeStrategy (tree-level)

    /// Replace the `strategy` of the container identified by `containerID`
    /// with `newKind` (plan §P4.5). The tree topology and container identity
    /// are untouched — only the strategy is rewritten. `weights` are kept
    /// verbatim (grid ignores them, master-stack continues to use
    /// `weights[0]` as the master ratio).
    ///
    /// Returns `nil` when the container is not found **or** `newKind` equals
    /// the current strategy (NOOP). Callers can treat `nil` as "no state
    /// change, skip broadcasting a layoutUpdate."
    public static func changeStrategy(
        tree: PaneNode,
        containerID: UUID,
        newKind: LayoutStrategyKind
    ) -> PaneNode? {
        replaceContainerStrategy(
            node: tree,
            containerID: containerID,
            newKind: newKind
        )
    }

    private static func replaceContainerStrategy(
        node: PaneNode,
        containerID: UUID,
        newKind: LayoutStrategyKind
    ) -> PaneNode? {
        switch node {
        case .leaf:
            return nil
        case .container(let c):
            if c.id == containerID {
                guard c.strategy != newKind else { return nil }
                return .container(Container(
                    id: c.id,
                    strategy: newKind,
                    children: c.children,
                    weights: c.weights
                ))
            }
            for (i, child) in c.children.enumerated() {
                guard let replaced = replaceContainerStrategy(
                    node: child,
                    containerID: containerID,
                    newKind: newKind
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

    // MARK: - parentContainer (tree-level)

    /// Return the container that directly holds `paneID` as a leaf child, or
    /// `nil` when `paneID` is the tree's sole root leaf (no parent) or is
    /// not in the tree. Used by callers that need to act on "the container
    /// owning the focused pane" (plan §P4.5 — changeStrategy target).
    public static func parentContainer(tree: PaneNode, paneID: UUID) -> Container? {
        findParentContainer(node: tree, paneID: paneID)
    }

    private static func findParentContainer(
        node: PaneNode,
        paneID: UUID
    ) -> Container? {
        switch node {
        case .leaf:
            return nil
        case .container(let c):
            for child in c.children {
                if case .leaf(let pane) = child, pane.id == paneID {
                    return c
                }
            }
            for child in c.children {
                if let found = findParentContainer(node: child, paneID: paneID) {
                    return found
                }
            }
            return nil
        }
    }

    // MARK: - flattenToStrategy (tree-level)

    /// Collapse `tree` into a single flat container with `newKind`, placing
    /// every leaf as a direct child in depth-first order (plan §P4.5). This
    /// is the "one strategy per tab" rewrite: when the user picks a new
    /// layout we abandon all prior nesting and weight distribution and
    /// re-tile every pane under the requested strategy.
    ///
    /// Initial weights & structure:
    /// - `.masterStack` follows plan §3.5 — `weights[0] = 1.5 × stackSum` so
    ///   the master column stays around 60% regardless of how many stack
    ///   panes there are. Stack weights are all `1.0`.
    /// - `.grid` is a **reshape-only** strategy: the result is a nested
    ///   `H[V[…], V[…], …]` row-major tree so all runtime layout and
    ///   divider dragging reuses the 1-D pipeline. `.grid` never appears as
    ///   a container strategy in the returned tree. `(R, C)` is picked from
    ///   `round(√N) × ⌈N/R⌉` — pane-count only, no parent-rect dependency.
    /// - `.horizontal` / `.vertical` / `.fibonacci` get a flat container
    ///   with equal weights.
    ///
    /// The new container gets a fresh UUID — any persisted reference to the
    /// old container IDs (there shouldn't be any outside this engine) becomes
    /// stale. Leaf `TerminalPane` values are preserved verbatim so focus
    /// and zoom state remain valid.
    ///
    /// Returns `nil` when the call is a NOOP:
    /// - `tree` is a single leaf (single-pane tab — no container exists to
    ///   host a strategy), or
    /// - `tree` is already a flat container (all children leaves) using
    ///   `newKind`, so flattening would produce the same layout, or
    /// - `newKind == .grid` and `tree` already matches the canonical nested
    ///   grid shape for its pane count (ignoring container UUIDs).
    public static func flattenToStrategy(
        tree: PaneNode,
        newKind: LayoutStrategyKind
    ) -> PaneNode? {
        let panes = tree.allPanes
        guard panes.count >= 2 else { return nil }

        if newKind == .grid {
            let candidate = buildGridTree(panes: panes)
            return sameShape(tree, candidate) ? nil : candidate
        }

        if case .container(let c) = tree,
           c.strategy == newKind,
           c.children.allSatisfy({ if case .leaf = $0 { true } else { false } }) {
            return nil
        }
        let weights: [CGFloat]
        if newKind == .masterStack {
            let stackCount = panes.count - 1
            weights = [1.5 * CGFloat(stackCount)] + Array(repeating: 1.0, count: stackCount)
        } else {
            weights = Array(repeating: 1.0, count: panes.count)
        }
        return .container(Container(
            strategy: newKind,
            children: panes.map { .leaf($0) },
            weights: weights
        ))
    }

    /// Build the canonical nested grid tree for `panes` in row-major order.
    /// Outer container is `.horizontal` (rows stacked top-to-bottom); each
    /// row is a `.vertical` container (panes stacked left-to-right), except
    /// when a row has a single pane, in which case the bare leaf is used so
    /// the last-row pane naturally spans the full width.
    ///
    /// Special cases:
    /// - `R == 1`: the outer `.horizontal` would wrap a single child, so we
    ///   return the inner row directly (a plain `.vertical` for N ≥ 2).
    /// - Last row with 1 pane: inserted as a bare `.leaf`, not a 1-child
    ///   container, keeping the tree well-formed.
    private static func buildGridTree(panes: [TerminalPane]) -> PaneNode {
        precondition(panes.count >= 2, "grid shape requires at least 2 panes")
        let n = panes.count
        let r = max(1, Int(Double(n).squareRoot().rounded()))
        let c = Int((Double(n) / Double(r)).rounded(.up))

        var rows: [PaneNode] = []
        var cursor = 0
        while cursor < n {
            let rowCount = min(c, n - cursor)
            let slice = Array(panes[cursor..<(cursor + rowCount)])
            cursor += rowCount
            if slice.count == 1 {
                rows.append(.leaf(slice[0]))
            } else {
                rows.append(.container(Container(
                    strategy: .vertical,
                    children: slice.map { .leaf($0) },
                    weights: Array(repeating: 1.0, count: slice.count)
                )))
            }
        }
        // R == 1 (e.g. N == 2): outer H would wrap a single V — collapse it.
        if rows.count == 1 { return rows[0] }
        return .container(Container(
            strategy: .horizontal,
            children: rows,
            weights: Array(repeating: 1.0, count: rows.count)
        ))
    }

    /// Tree shape equality that ignores container UUIDs. `flattenToStrategy`
    /// uses this for grid NOOP detection: the rebuilt tree always has fresh
    /// container IDs so plain `==` would never match, but structurally the
    /// trees can still be identical.
    private static func sameShape(_ a: PaneNode, _ b: PaneNode) -> Bool {
        switch (a, b) {
        case (.leaf(let p1), .leaf(let p2)):
            return p1.id == p2.id
        case (.container(let c1), .container(let c2)):
            return c1.strategy == c2.strategy
                && c1.weights == c2.weights
                && c1.children.count == c2.children.count
                && zip(c1.children, c2.children).allSatisfy(sameShape)
        default:
            return false
        }
    }

    // MARK: - strategy cycling

    /// Ordered strategies exposed to interactive cycling (plan §P4.5).
    /// `.fibonacci` is omitted until its solver lands.
    public static let userCycleableStrategies: [LayoutStrategyKind] = [
        .horizontal, .vertical, .grid, .masterStack
    ]

    /// Compute the next strategy relative to `current` in
    /// `userCycleableStrategies`. `forward == true` advances, `false` steps
    /// back. A `current` that is not in the cycle list (e.g. `.fibonacci`)
    /// anchors on the first entry so the cycle is still well-defined.
    public static func nextStrategy(
        current: LayoutStrategyKind,
        forward: Bool
    ) -> LayoutStrategyKind {
        let order = userCycleableStrategies
        let count = order.count
        let baseIndex = order.firstIndex(of: current) ?? 0
        let nextIndex = forward
            ? (baseIndex + 1) % count
            : (baseIndex - 1 + count) % count
        return order[nextIndex]
    }

    // MARK: - sanitize (tree-level)

    /// Re-establish `Container` invariants:
    /// - Rule 1: containers with no leaves are removed.
    /// - Rule 2: single-child containers are replaced by their sole child.
    /// - Rule 3: a container whose child is a container with the same
    ///   strategy is flattened; the child's weights scale so the group's
    ///   cumulative share matches the original slot weight.
    ///
    /// Called internally after `movePane`'s removal phase and after the
    /// reinsertion phase; also invoked by `updateActivePaneTree`-style
    /// external writes.
    public static func sanitize(tree: PaneNode) -> PaneNode {
        let cleanedTree = cleaned(node: tree) ?? tree
        return merged(node: cleanedTree)
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

    /// Bottom-up rule-3 merge. A container whose child is another container
    /// with matching strategy absorbs the child's children in place. The
    /// absorbed sub-weights are scaled by `slot_weight / sub_total` so the
    /// combined share of the injected children equals the slot the merged
    /// container used to occupy.
    private static func merged(node: PaneNode) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case .container(let c):
            let recursed = c.children.map { merged(node: $0) }
            var newChildren: [PaneNode] = []
            var newWeights: [CGFloat] = []
            for (child, weight) in zip(recursed, c.weights) {
                if case .container(let sub) = child, sub.strategy == c.strategy {
                    let subTotal = sub.weights.reduce(0, +)
                    let scale = subTotal > 0 ? weight / subTotal : 0
                    for (subChild, subWeight) in zip(sub.children, sub.weights) {
                        newChildren.append(subChild)
                        newWeights.append(subWeight * scale)
                    }
                } else {
                    newChildren.append(child)
                    newWeights.append(weight)
                }
            }
            guard newChildren != c.children else { return node }
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

    /// `TerminalTab` convenience over `swapPanes(tree:…)`.
    public static func swapPanes(tab: TerminalTab, a: UUID, b: UUID) -> TerminalTab? {
        guard let newTree = swapPanes(tree: tab.paneTree, a: a, b: b) else { return nil }
        var next = tab
        next.paneTree = newTree
        return next
    }

    /// `TerminalTab` convenience over `movePane(tree:…)`. `focusedPaneID`
    /// is preserved: the source pane keeps its UUID across the move, so if
    /// focus was on it, the tab's recorded focus stays valid.
    public static func movePane(
        tab: TerminalTab,
        sourceID: UUID,
        targetID: UUID,
        side: FocusDirection
    ) -> TerminalTab? {
        guard let newTree = movePane(
            tree: tab.paneTree,
            sourceID: sourceID,
            targetID: targetID,
            side: side
        ) else { return nil }
        var next = tab
        next.paneTree = newTree
        return next
    }

    /// `TerminalTab` convenience over `changeStrategy(tree:…)`.
    public static func changeStrategy(
        tab: TerminalTab,
        containerID: UUID,
        newKind: LayoutStrategyKind
    ) -> TerminalTab? {
        guard let newTree = changeStrategy(
            tree: tab.paneTree,
            containerID: containerID,
            newKind: newKind
        ) else { return nil }
        var next = tab
        next.paneTree = newTree
        return next
    }

    /// `TerminalTab` convenience over `flattenToStrategy(tree:…)`.
    /// `focusedPaneID` and `zoomedPaneID` are preserved because every leaf's
    /// UUID survives the rewrite.
    public static func flattenToStrategy(
        tab: TerminalTab,
        newKind: LayoutStrategyKind
    ) -> TerminalTab? {
        guard let newTree = flattenToStrategy(
            tree: tab.paneTree,
            newKind: newKind
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
