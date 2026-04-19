import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("PaneNode")
struct PaneNodeTests {

    // MARK: - Helpers

    /// Build a 2-child `.container` node (BSP-compatible shape produced by
    /// `PaneNode.split` during P2). `ratio` is the first child's weight share.
    private func twoChildContainer(
        strategy: LayoutStrategyKind,
        first: PaneNode,
        second: PaneNode,
        ratio: CGFloat = 0.5
    ) -> PaneNode {
        .container(Container(
            strategy: strategy,
            children: [first, second],
            weights: [ratio, 1.0 - ratio]
        ))
    }

    // MARK: - Leaf

    @Test func leafAllPanes() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)

        #expect(node.allPanes.count == 1)
        #expect(node.allPanes[0].id == pane.id)
        #expect(node.allPaneIDs == [pane.id])
        #expect(node.paneCount == 1)
    }

    @Test func leafFindPane() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)

        #expect(node.findPane(id: pane.id)?.id == pane.id)
        #expect(node.findPane(id: UUID()) == nil)
        #expect(node.contains(paneID: pane.id))
        #expect(!node.contains(paneID: UUID()))
    }

    @Test func leafRootPane() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)

        #expect(node.rootPane?.id == pane.id)
    }

    // MARK: - Container

    @Test func containerAllPanes() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        #expect(node.allPanes.count == 2)
        #expect(node.allPaneIDs == [pane1.id, pane2.id])
        #expect(node.paneCount == 2)
        #expect(node.rootPane == nil)
    }

    @Test func containerFindPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        #expect(node.findPane(id: pane1.id)?.id == pane1.id)
        #expect(node.findPane(id: pane2.id)?.id == pane2.id)
        #expect(node.findPane(id: UUID()) == nil)
    }

    @Test func nAryContainerAllPanes() {
        // N-ary container (may appear once P3 flattening lands; the model
        // itself supports it already).
        let panes = [TerminalPane(), TerminalPane(), TerminalPane(), TerminalPane()]
        let node = PaneNode.container(Container(
            strategy: .vertical,
            children: panes.map { .leaf($0) },
            weights: [1.0, 2.0, 1.5, 0.5]
        ))

        #expect(node.paneCount == 4)
        #expect(node.allPaneIDs == panes.map(\.id))
    }

    // MARK: - Split Mutation

    @Test func splitLeaf() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.leaf(pane1)

        let result = node.split(paneID: pane1.id, direction: .vertical, newPane: pane2)
        #expect(result != nil)
        #expect(result!.paneCount == 2)
        #expect(result!.allPaneIDs == [pane1.id, pane2.id])

        if case .container(let c) = result! {
            #expect(c.strategy == .vertical)
            #expect(c.children.count == 2)
            #expect(c.weights == [1.0, 1.0])
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func splitLeafNotFound() {
        let pane1 = TerminalPane()
        let node = PaneNode.leaf(pane1)

        let result = node.split(paneID: UUID(), direction: .vertical, newPane: TerminalPane())
        #expect(result == nil)
    }

    @Test func splitNestedPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        // Split pane2 horizontally (different direction ⇒ new nested container).
        let result = node.split(paneID: pane2.id, direction: .horizontal, newPane: pane3)
        #expect(result != nil)
        #expect(result!.paneCount == 3)
        #expect(result!.allPaneIDs == [pane1.id, pane2.id, pane3.id])
    }

    // MARK: - Remove

    @Test func removeOnlyLeaf() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)

        let result = node.removePane(id: pane.id)
        #expect(result == nil)
    }

    @Test func removeFirstChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        let result = node.removePane(id: pane1.id)
        #expect(result != nil)
        // Sibling promoted (container collapses to single remaining leaf).
        if case .leaf(let pane) = result! {
            #expect(pane.id == pane2.id)
        } else {
            Issue.record("Expected leaf after removing sibling")
        }
    }

    @Test func removeSecondChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .horizontal, first: .leaf(pane1), second: .leaf(pane2), ratio: 0.6)

        let result = node.removePane(id: pane2.id)
        #expect(result != nil)
        if case .leaf(let pane) = result! {
            #expect(pane.id == pane1.id)
        } else {
            Issue.record("Expected leaf after removing sibling")
        }
    }

    @Test func removeNestedPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()

        // Structure: container(vertical, leaf(pane1), container(horizontal, leaf(pane2), leaf(pane3)))
        let inner = twoChildContainer(strategy: .horizontal, first: .leaf(pane2), second: .leaf(pane3))
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: inner)

        // Remove pane3 → inner collapses to leaf(pane2) → outer stays 2-child container.
        let result = node.removePane(id: pane3.id)
        #expect(result != nil)
        #expect(result!.paneCount == 2)
        #expect(result!.allPaneIDs == [pane1.id, pane2.id])
    }

    @Test func removeNonExistentPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        let result = node.removePane(id: UUID())
        // Unchanged.
        #expect(result == node)
    }

    @Test func removeMiddleChildOfNAry() {
        // Container with 3+ children must shrink in place (not collapse).
        let panes = [TerminalPane(), TerminalPane(), TerminalPane()]
        let node = PaneNode.container(Container(
            strategy: .vertical,
            children: panes.map { .leaf($0) },
            weights: [1.0, 2.0, 3.0]
        ))

        let result = node.removePane(id: panes[1].id)
        #expect(result != nil)
        guard case .container(let c) = result! else {
            Issue.record("Expected container to remain after removing one of three children")
            return
        }
        #expect(c.children.count == 2)
        #expect(c.weights == [1.0, 3.0])  // middle weight dropped
        #expect(result!.allPaneIDs == [panes[0].id, panes[2].id])
    }

    // MARK: - Update Ratio

    @Test func updateRatioDirectChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        let result = node.updateRatio(for: pane1.id, newRatio: 0.7)
        if case .container(let c) = result {
            #expect(abs(c.weights[0] - 0.7) < 0.0001)
            #expect(abs(c.weights[1] - 0.3) < 0.0001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func updateRatioSecondChildInverts() {
        // newRatio is the target's weight share; sibling gets 1-newRatio.
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        let result = node.updateRatio(for: pane2.id, newRatio: 0.2)
        if case .container(let c) = result {
            #expect(abs(c.weights[0] - 0.8) < 0.0001)
            #expect(abs(c.weights[1] - 0.2) < 0.0001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func updateRatioNestedChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()

        let inner = twoChildContainer(strategy: .horizontal, first: .leaf(pane2), second: .leaf(pane3))
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: inner)

        let result = node.updateRatio(for: pane2.id, newRatio: 0.3)

        guard case .container(let outer) = result else {
            Issue.record("Expected outer container")
            return
        }
        // Outer weights unchanged.
        #expect(outer.weights[0] == 0.5)
        #expect(outer.weights[1] == 0.5)
        // Inner weights updated.
        guard case .container(let innerC) = outer.children[1] else {
            Issue.record("Expected inner container")
            return
        }
        #expect(abs(innerC.weights[0] - 0.3) < 0.0001)
        #expect(abs(innerC.weights[1] - 0.7) < 0.0001)
    }

    // MARK: - Resize

    @Test func resizeFirstChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        // Grow first child: weight share goes from 0.5 to 0.6.
        let result = node.resizePane(id: pane1.id, delta: 0.1)
        #expect(result != nil)
        if case .container(let c) = result! {
            let sum = c.weights.reduce(0, +)
            #expect(abs(c.weights[0] / sum - 0.6) < 0.001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func resizeSecondChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        // Grow second child by +0.1: its share goes 0.5 → 0.6, first shrinks to 0.4.
        let result = node.resizePane(id: pane2.id, delta: 0.1)
        #expect(result != nil)
        if case .container(let c) = result! {
            let sum = c.weights.reduce(0, +)
            #expect(abs(c.weights[0] / sum - 0.4) < 0.001)
            #expect(abs(c.weights[1] / sum - 0.6) < 0.001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func resizeClampsToMin() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(
            strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2), ratio: 0.15
        )

        // Shrink first child below the 10% floor: clamped to 0.1.
        let result = node.resizePane(id: pane1.id, delta: -0.1)
        #expect(result != nil)
        if case .container(let c) = result! {
            let sum = c.weights.reduce(0, +)
            #expect(abs(c.weights[0] / sum - 0.1) < 0.001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func resizeClampsToMax() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(
            strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2), ratio: 0.85
        )

        // Grow first child beyond the 90% ceiling: clamped to 0.9.
        let result = node.resizePane(id: pane1.id, delta: 0.1)
        #expect(result != nil)
        if case .container(let c) = result! {
            let sum = c.weights.reduce(0, +)
            #expect(abs(c.weights[0] / sum - 0.9) < 0.001)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func resizeNestedPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()

        let inner = twoChildContainer(strategy: .horizontal, first: .leaf(pane2), second: .leaf(pane3))
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: inner)

        // Resize pane2 (inner container's first child).
        let result = node.resizePane(id: pane2.id, delta: 0.1)
        #expect(result != nil)

        guard case .container(let outer) = result! else {
            Issue.record("Expected outer container")
            return
        }
        // Outer weights unchanged.
        let outerSum = outer.weights.reduce(0, +)
        #expect(abs(outer.weights[0] / outerSum - 0.5) < 0.001)

        guard case .container(let innerC) = outer.children[1] else {
            Issue.record("Expected inner container")
            return
        }
        let innerSum = innerC.weights.reduce(0, +)
        #expect(abs(innerC.weights[0] / innerSum - 0.6) < 0.001)
    }

    @Test func resizeLeafReturnsNil() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)
        #expect(node.resizePane(id: pane.id, delta: 0.1) == nil)
    }

    @Test func resizeNonExistentReturnsNil() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))
        #expect(node.resizePane(id: UUID(), delta: 0.1) == nil)
    }

    // MARK: - Replace

    @Test func replacingPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let paneNew = TerminalPane()
        let node = twoChildContainer(strategy: .vertical, first: .leaf(pane1), second: .leaf(pane2))

        let result = node.replacingPane(id: pane1.id, with: .leaf(paneNew))
        #expect(result.allPaneIDs == [paneNew.id, pane2.id])
    }

    // MARK: - TerminalTab Integration

    @Test func terminalTabAllPaneIDs() {
        let tab = TerminalTab(title: "test")
        #expect(tab.allPaneIDs.count == 1)
        #expect(tab.paneTree.rootPane != nil)
    }

    @Test func terminalTabZoomedPaneIDDefaultsNil() {
        let tab = TerminalTab(title: "test")
        #expect(tab.zoomedPaneID == nil)
    }
}
