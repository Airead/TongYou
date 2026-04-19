import Foundation
import Testing
@testable import TYTerminal

@Suite("LayoutEngine", .serialized)
struct LayoutEngineTests {

    // MARK: - Helpers

    private func makeTab(_ tree: PaneNode, focused: UUID? = nil) -> TerminalTab {
        TerminalTab(
            id: UUID(),
            title: "t",
            paneTree: tree,
            floatingPanes: [],
            focusedPaneID: focused
        )
    }

    private func leaf() -> (TerminalPane, PaneNode) {
        let p = TerminalPane()
        return (p, .leaf(p))
    }

    private func container(
        _ strategy: LayoutStrategyKind,
        _ children: [PaneNode],
        _ weights: [CGFloat]
    ) -> PaneNode {
        .container(Container(strategy: strategy, children: children, weights: weights))
    }

    // MARK: - splitPane (flattening)

    @Test func splitSingleLeafWrapsInContainer() {
        let (a, leafA) = leaf()
        let tab = makeTab(leafA)
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: a.id,
            direction: .vertical, newPane: newPane
        )

        guard case .container(let c) = out?.paneTree else {
            Issue.record("expected container root"); return
        }
        #expect(c.strategy == .vertical)
        #expect(c.children.count == 2)
        #expect(c.weights == [1.0, 1.0])
        #expect(c.children[0].allPaneIDs == [a.id])
        #expect(c.children[1].allPaneIDs == [newPane.id])
    }

    @Test func splitSameDirectionFlattensIntoParent() {
        // V[A, B] + split B rightwards → V[A, B, new] (flattened, not nested)
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let tab = makeTab(tree)
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: b.id,
            direction: .vertical, newPane: newPane
        )

        guard case .container(let c) = out?.paneTree else {
            Issue.record("expected container root"); return
        }
        #expect(c.strategy == .vertical)
        #expect(c.children.count == 3)
        #expect(c.weights == [1, 1, 1])
        #expect(c.children[0].allPaneIDs == [a.id])
        #expect(c.children[1].allPaneIDs == [b.id])
        #expect(c.children[2].allPaneIDs == [newPane.id])
    }

    @Test func splitPreservesExistingWeights() {
        // V[A(2), B(1)] + split A rightwards → V[A(2), new(1), B(1)]
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [2, 1])
        let tab = makeTab(tree)
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: a.id,
            direction: .vertical, newPane: newPane
        )

        guard case .container(let c) = out?.paneTree else {
            Issue.record("expected container root"); return
        }
        // Old weights untouched; new child inserted right after A with weight 1.
        #expect(c.weights == [2, 1, 1])
        #expect(c.children[0].allPaneIDs == [a.id])
        #expect(c.children[1].allPaneIDs == [newPane.id])
        #expect(c.children[2].allPaneIDs == [b.id])
    }

    @Test func splitOppositeDirectionWrapsTargetInNewContainer() {
        // V[A, B] + split B downwards (.horizontal) → V[A, H[B, new]]
        let (_, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let tab = makeTab(tree)
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: b.id,
            direction: .horizontal, newPane: newPane
        )

        guard case .container(let outer) = out?.paneTree else {
            Issue.record("expected outer container"); return
        }
        #expect(outer.strategy == .vertical)
        #expect(outer.children.count == 2)
        #expect(outer.weights == [1, 1])
        guard case .container(let inner) = outer.children[1] else {
            Issue.record("expected inner container replacing B"); return
        }
        #expect(inner.strategy == .horizontal)
        #expect(inner.children.count == 2)
        #expect(inner.weights == [1, 1])
        #expect(inner.children[0].allPaneIDs == [b.id])
        #expect(inner.children[1].allPaneIDs == [newPane.id])
    }

    @Test func splitFiveTimesSameDirectionProducesFlatContainer() {
        // Simulate the user mashing "split right" 5 times starting from a
        // single pane. Plan §P3 verification: result is 1 V container with 6
        // leaves (not a 6-deep nest).
        let initial = TerminalPane()
        var tab = makeTab(.leaf(initial))
        var target = initial.id
        var newIDs: [UUID] = []
        for _ in 0..<5 {
            let fresh = TerminalPane()
            newIDs.append(fresh.id)
            let next = LayoutEngine.splitPane(
                tab: tab, targetPaneID: target,
                direction: .vertical, newPane: fresh
            )
            tab = next ?? tab
            target = fresh.id   // keep splitting the most-recent pane
        }

        guard case .container(let c) = tab.paneTree else {
            Issue.record("expected container root"); return
        }
        #expect(c.strategy == .vertical)
        #expect(c.children.count == 6)
        #expect(c.children.allSatisfy { if case .leaf = $0 { true } else { false } })
        // Order: initial, then each new pane inserted after the previous.
        let expectedIDs = [initial.id] + newIDs
        #expect(c.children.map { $0.allPaneIDs[0] } == expectedIDs)
    }

    @Test func splitInNestedSubtreeFlattensAgainstInnerParent() {
        // H[A, V[B, C]] + split C rightwards → H[A, V[B, C, new]]
        let (_, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let inner = container(.vertical, [leafB, leafC], [1, 1])
        let root = container(.horizontal, [leafA, inner], [1, 1])
        let tab = makeTab(root)
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: c.id,
            direction: .vertical, newPane: newPane
        )

        guard case .container(let outer) = out?.paneTree else {
            Issue.record("expected outer container"); return
        }
        #expect(outer.strategy == .horizontal)
        guard case .container(let innerOut) = outer.children[1] else {
            Issue.record("expected inner container at index 1"); return
        }
        #expect(innerOut.strategy == .vertical)
        #expect(innerOut.children.count == 3)
        #expect(innerOut.children.map { $0.allPaneIDs[0] } == [b.id, c.id, newPane.id])
    }

    @Test func splitReturnsNilForUnknownPaneID() {
        let tab = makeTab(.leaf(TerminalPane()))
        let out = LayoutEngine.splitPane(
            tab: tab, targetPaneID: UUID(),
            direction: .vertical, newPane: TerminalPane()
        )
        #expect(out == nil)
    }

    // MARK: - closePane

    @Test func closeLastPaneReportsEmptiedTree() {
        let (a, leafA) = leaf()
        let tab = makeTab(leafA)
        let outcome = LayoutEngine.closePane(tab: tab, paneID: a.id)
        #expect(outcome != nil)
        if case .emptiedTree = outcome {} else {
            Issue.record("expected .emptiedTree")
        }
    }

    @Test func closeMiddleOfFlatContainerKeepsOtherWeights() {
        // V[A(2), B(3), C(5)] remove B → V[A(2), C(5)]; sibling weights intact.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [2, 3, 5])
        let tab = makeTab(tree, focused: b.id)

        guard case .closed(let newTab, let promoted) = LayoutEngine.closePane(tab: tab, paneID: b.id) else {
            Issue.record("expected .closed"); return
        }
        guard case .container(let cc) = newTab.paneTree else {
            Issue.record("expected container"); return
        }
        #expect(cc.children.map { $0.allPaneIDs[0] } == [a.id, c.id])
        #expect(cc.weights == [2, 5])
        // Focused pane was removed → promoted to tree.firstPane (A).
        #expect(promoted == a.id)
        #expect(newTab.focusedPaneID == a.id)
    }

    @Test func closeDownToSingleChildCollapsesContainer() {
        // V[A, B] remove A → bare leaf B (collapse rule).
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let tab = makeTab(tree)

        guard case .closed(let newTab, let promoted) = LayoutEngine.closePane(tab: tab, paneID: a.id) else {
            Issue.record("expected .closed"); return
        }
        if case .leaf(let p) = newTab.paneTree {
            #expect(p.id == b.id)
        } else {
            Issue.record("expected leaf after collapse")
        }
        #expect(promoted == b.id)
    }

    @Test func closeReturnsNilForUnknownPaneID() {
        let tab = makeTab(.leaf(TerminalPane()))
        #expect(LayoutEngine.closePane(tab: tab, paneID: UUID()) == nil)
    }

    @Test func closePreservesUnrelatedFocus() {
        // Focus is on a surviving pane → should not be rewritten.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [1, 1, 1])
        let tab = makeTab(tree, focused: a.id)
        guard case .closed(let newTab, _) = LayoutEngine.closePane(tab: tab, paneID: b.id) else {
            Issue.record("expected .closed"); return
        }
        #expect(newTab.focusedPaneID == a.id)
    }

    // MARK: - resizePane

    @Test func resizeUpdatesTwoChildContainerWeights() {
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [0.5, 0.5])
        let tab = makeTab(tree)

        let out = LayoutEngine.resizePane(tab: tab, paneID: a.id, newRatio: 0.3)
        guard case .container(let c) = out?.paneTree else {
            Issue.record("expected container"); return
        }
        #expect(c.weights == [0.3, 0.7])
    }

    @Test func resizeReturnsNilForUnknownPaneID() {
        let tab = makeTab(.leaf(TerminalPane()))
        #expect(LayoutEngine.resizePane(tab: tab, paneID: UUID(), newRatio: 0.5) == nil)
    }

    // MARK: - solveRects

    @Test func solveRectsForSingleLeafMapsToScreenRect() {
        let (a, leafA) = leaf()
        let tab = makeTab(leafA)
        let screen = Rect(x: 0, y: 0, width: 80, height: 24)
        let rects = LayoutEngine.solveRects(tab: tab, screenRect: screen)
        #expect(rects == [a.id: screen])
    }

    @Test func solveRectsForFlatVerticalContainer() {
        // V[A, B, C] equal weights in a 90x30 rect → widths 30/30/30.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [1, 1, 1])
        let tab = makeTab(tree)
        let screen = Rect(x: 0, y: 0, width: 90, height: 30)
        let rects = LayoutEngine.solveRects(tab: tab, screenRect: screen)
        #expect(rects[a.id] == Rect(x: 0, y: 0, width: 30, height: 30))
        #expect(rects[b.id] == Rect(x: 30, y: 0, width: 30, height: 30))
        #expect(rects[c.id] == Rect(x: 60, y: 0, width: 30, height: 30))
    }

    @Test func solveRectsForNestedContainers() {
        // H[A, V[B, C]] in a 100x40 rect with H weights [1,1], V weights [1,1]:
        // A: top half (100 x 20); inner V occupies bottom half (100 x 20):
        //   B: left (50 x 20) at y=20; C: right (50 x 20) at x=50, y=20.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let inner = container(.vertical, [leafB, leafC], [1, 1])
        let root = container(.horizontal, [leafA, inner], [1, 1])
        let tab = makeTab(root)
        let screen = Rect(x: 0, y: 0, width: 100, height: 40)

        let rects = LayoutEngine.solveRects(tab: tab, screenRect: screen)
        #expect(rects[a.id] == Rect(x: 0, y: 0, width: 100, height: 20))
        #expect(rects[b.id] == Rect(x: 0, y: 20, width: 50, height: 20))
        #expect(rects[c.id] == Rect(x: 50, y: 20, width: 50, height: 20))
    }

    // MARK: - sanitize

    @Test func sanitizeLeavesWellFormedTreeUnchanged() {
        let (_, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let tab = makeTab(tree)
        let out = LayoutEngine.sanitize(tab: tab)
        #expect(out.paneTree == tab.paneTree)
    }

    @Test func sanitizeLeavesFlatThreeChildContainerAlone() {
        let (_, leafA) = leaf()
        let (_, leafB) = leaf()
        let (_, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [1, 1, 1])
        let tab = makeTab(tree)
        let out = LayoutEngine.sanitize(tab: tab)
        #expect(out.paneTree == tab.paneTree)
    }

    // MARK: - Tree-level entries (smoke coverage — same logic as tab-level)

    @Test func treeSplitAppliesFlattening() {
        // V[A, B] + split B rightwards via tree-level entry → V[A, B, new].
        let (_, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let newPane = TerminalPane()

        let out = LayoutEngine.splitPane(
            tree: tree, targetPaneID: b.id,
            direction: .vertical, newPane: newPane
        )
        guard case .container(let c) = out else {
            Issue.record("expected container root"); return
        }
        #expect(c.children.count == 3)
        #expect(c.children[2].allPaneIDs == [newPane.id])
    }

    @Test func treeCloseReportsEmptiedOnLastPane() {
        let (a, leafA) = leaf()
        let outcome = LayoutEngine.closePane(tree: leafA, paneID: a.id)
        if case .emptiedTree = outcome {} else {
            Issue.record("expected .emptiedTree")
        }
    }

    @Test func treeCloseCollapsesSingleChildContainer() {
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])

        guard case .closed(let newTree, let promoted) = LayoutEngine.closePane(tree: tree, paneID: a.id) else {
            Issue.record("expected .closed"); return
        }
        if case .leaf(let p) = newTree {
            #expect(p.id == b.id)
        } else {
            Issue.record("expected collapse to leaf")
        }
        #expect(promoted == b.id)
    }

    @Test func treeResizeUpdatesContainerWeights() {
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [0.5, 0.5])

        let out = LayoutEngine.resizePane(tree: tree, paneID: a.id, newRatio: 0.25)
        guard case .container(let c) = out else {
            Issue.record("expected container"); return
        }
        #expect(c.weights == [0.25, 0.75])
    }

    // MARK: - toggleZoom / solveRects with zoom

    @Test func toggleZoomSetsFieldOnFirstCall() {
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        let tab = makeTab(tree)

        let zoomed = LayoutEngine.toggleZoom(tab: tab, paneID: a.id)
        #expect(zoomed?.zoomedPaneID == a.id)
    }

    @Test func toggleZoomClearsWhenAlreadyZoomedPane() {
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        let out = LayoutEngine.toggleZoom(tab: tab, paneID: a.id)
        #expect(out?.zoomedPaneID == nil)
    }

    @Test func toggleZoomSwitchesToAnotherPane() {
        // Zooming a different pane while one is already zoomed switches —
        // it does not clear.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        let out = LayoutEngine.toggleZoom(tab: tab, paneID: b.id)
        #expect(out?.zoomedPaneID == b.id)
    }

    @Test func toggleZoomReturnsNilForUnknownPane() {
        let (_, leafA) = leaf()
        let tab = makeTab(leafA)
        #expect(LayoutEngine.toggleZoom(tab: tab, paneID: UUID()) == nil)
    }

    @Test func solveRectsHonorsZoomedPaneID() {
        // With zoomedPaneID set, every other pane drops out of the result
        // and the zoomed pane fills the full screen rect.
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let (_, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [1, 1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        let screen = Rect(x: 0, y: 0, width: 120, height: 40)
        let rects = LayoutEngine.solveRects(tab: tab, screenRect: screen)
        #expect(rects == [a.id: screen])
    }

    @Test func solveRectsIgnoresStaleZoomedPaneID() {
        // zoomedPaneID points to a pane no longer in the tree → normal
        // tiled layout is returned.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = UUID()  // unknown

        let screen = Rect(x: 0, y: 0, width: 100, height: 30)
        let rects = LayoutEngine.solveRects(tab: tab, screenRect: screen)
        #expect(rects[a.id] == Rect(x: 0, y: 0, width: 50, height: 30))
        #expect(rects[b.id] == Rect(x: 50, y: 0, width: 50, height: 30))
        #expect(rects.count == 2)
    }

    @Test func closePaneClearsZoomWhenZoomedPaneRemoved() {
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        guard case .closed(let newTab, _) = LayoutEngine.closePane(tab: tab, paneID: a.id) else {
            Issue.record("expected .closed"); return
        }
        #expect(newTab.zoomedPaneID == nil)
        // Zoom was on A; surviving tree is just leaf B.
        if case .leaf(let p) = newTab.paneTree {
            #expect(p.id == b.id)
        } else {
            Issue.record("expected collapsed leaf")
        }
    }

    @Test func closePaneKeepsZoomWhenOtherPaneRemoved() {
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (_, leafC) = leaf()
        let tree = container(.vertical, [leafA, leafB, leafC], [1, 1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        guard case .closed(let newTab, _) = LayoutEngine.closePane(tab: tab, paneID: b.id) else {
            Issue.record("expected .closed"); return
        }
        #expect(newTab.zoomedPaneID == a.id)
    }

    @Test func sanitizeDropsStaleZoomedPaneID() {
        // External tree write leaves `zoomedPaneID` pointing at a UUID that
        // no longer exists in the tree → sanitize clears it.
        let (_, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = UUID()  // stale

        let out = LayoutEngine.sanitize(tab: tab)
        #expect(out.zoomedPaneID == nil)
        #expect(out.paneTree == tree)
    }

    @Test func sanitizePreservesValidZoomedPaneID() {
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tree = container(.vertical, [leafA, leafB], [1, 1])
        var tab = makeTab(tree)
        tab.zoomedPaneID = a.id

        let out = LayoutEngine.sanitize(tab: tab)
        #expect(out.zoomedPaneID == a.id)
    }

    @Test func treeSanitizeCollapsesSingleChildContainer() {
        // Construct a deliberately-invalid tree: outer container with a
        // single child (should collapse under sanitize).
        let (a, leafA) = leaf()
        let inner = PaneNode.container(Container(
            strategy: .vertical, children: [leafA], weights: [1]
        ))
        let out = LayoutEngine.sanitize(tree: inner)
        if case .leaf(let p) = out {
            #expect(p.id == a.id)
        } else {
            Issue.record("expected single-child container to collapse")
        }
    }

    // MARK: - focusNeighbor (plan §P4.2)

    private let canvas = Rect(x: 0, y: 0, width: 100, height: 40)

    @Test func focusNeighborFlatSideBySide() {
        // V[A, B] — A left, B right.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tab = makeTab(container(.vertical, [leafA, leafB], [1, 1]))

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .right) == b.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .left) == a.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .left) == nil)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .right) == nil)
    }

    @Test func focusNeighborFlatStacked() {
        // H[A, B] — A top, B bottom.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let tab = makeTab(container(.horizontal, [leafA, leafB], [1, 1]))

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .down) == b.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .up) == a.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .up) == nil)
    }

    @Test func focusNeighborReturnsNilForOrthogonalDirection() {
        // In a side-by-side layout there is no up/down neighbor.
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let tab = makeTab(container(.vertical, [leafA, leafB], [1, 1]))

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .up) == nil)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .down) == nil)
    }

    @Test func focusNeighborPrefersLongestOverlap() {
        // V[A, H[B, C]] with H weights [1, 2] — A right maps to C (larger
        // vertical overlap) rather than B.
        let (a, leafA) = leaf()
        let (_, leafB) = leaf()
        let (c, leafC) = leaf()
        let tree = container(
            .vertical,
            [leafA, container(.horizontal, [leafB, leafC], [1, 2])],
            [1, 1]
        )
        let tab = makeTab(tree)

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .right) == c.id)
    }

    @Test func focusNeighborCrossesContainerBoundaries() {
        // V[A, H[B, C]] — moving left from either B or C lands on A.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let tree = container(
            .vertical,
            [leafA, container(.horizontal, [leafB, leafC], [1, 1])],
            [1, 1]
        )
        let tab = makeTab(tree)

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .left) == a.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: c.id, direction: .left) == a.id)
        // Within the inner container, B and C are each other's vertical neighbors.
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .down) == c.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: c.id, direction: .up) == b.id)
    }

    @Test func focusNeighborReturnsNilWhenZoomed() {
        // With zoom active, only the zoomed pane exists in solveRects — no
        // neighbor is reachable in any direction.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        var tab = makeTab(container(.vertical, [leafA, leafB], [1, 1]))
        tab.zoomedPaneID = a.id

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .right) == nil)
        // The hidden pane is not in solveRects output either.
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: b.id, direction: .left) == nil)
    }

    @Test func focusNeighborReturnsNilForUnknownSource() {
        let (_, leafA) = leaf()
        let (_, leafB) = leaf()
        let tab = makeTab(container(.vertical, [leafA, leafB], [1, 1]))

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: UUID(), direction: .right) == nil)
    }

    @Test func focusNeighborIgnoresCornerOnlyTouch() {
        // H[V[A, C], V[D, B]] — four quadrants: A top-left, C top-right,
        // D bottom-left, B bottom-right. A's bottom-right corner touches
        // B's top-left corner, but they share no edge overlap — A moving
        // down must land on D, never B; A moving right must land on C,
        // never B.
        let (a, leafA) = leaf()
        let (b, leafB) = leaf()
        let (c, leafC) = leaf()
        let (d, leafD) = leaf()
        let tree = container(
            .horizontal,
            [
                container(.vertical, [leafA, leafC], [1, 1]),
                container(.vertical, [leafD, leafB], [1, 1]),
            ],
            [1, 1]
        )
        let tab = makeTab(tree)

        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .right) == c.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: a.id, direction: .down) == d.id)
        // Sanity: B is reachable via its flush neighbors, just not from A.
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: c.id, direction: .down) == b.id)
        #expect(LayoutEngine.focusNeighbor(tab: tab, screenRect: canvas, from: d.id, direction: .right) == b.id)
    }
}
