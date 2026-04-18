import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("PaneNode")
struct PaneNodeTests {

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

    // MARK: - Split

    @Test func splitAllPanes() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        #expect(node.allPanes.count == 2)
        #expect(node.allPaneIDs == [pane1.id, pane2.id])
        #expect(node.paneCount == 2)
        #expect(node.rootPane == nil)
    }

    @Test func splitFindPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        #expect(node.findPane(id: pane1.id)?.id == pane1.id)
        #expect(node.findPane(id: pane2.id)?.id == pane2.id)
        #expect(node.findPane(id: UUID()) == nil)
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

        if case .split(let dir, let ratio, _, _) = result! {
            #expect(dir == .vertical)
            #expect(ratio == 0.5)
        } else {
            Issue.record("Expected split node")
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
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        // Split pane2 horizontally.
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
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        let result = node.removePane(id: pane1.id)
        #expect(result != nil)
        // Sibling promoted.
        if case .leaf(let pane) = result! {
            #expect(pane.id == pane2.id)
        } else {
            Issue.record("Expected leaf after removing sibling")
        }
    }

    @Test func removeSecondChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .horizontal,
            ratio: 0.6,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

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

        // Structure: split(vertical, leaf(pane1), split(horizontal, leaf(pane2), leaf(pane3)))
        let inner = PaneNode.split(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(pane2),
            second: .leaf(pane3)
        )
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: inner
        )

        // Remove pane3 → inner becomes leaf(pane2) → outer becomes split(vert, leaf(pane1), leaf(pane2))
        let result = node.removePane(id: pane3.id)
        #expect(result != nil)
        #expect(result!.paneCount == 2)
        #expect(result!.allPaneIDs == [pane1.id, pane2.id])
    }

    @Test func removeNonExistentPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        let result = node.removePane(id: UUID())
        // Unchanged.
        #expect(result == node)
    }

    // MARK: - Update Ratio

    @Test func updateRatioDirectChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        let result = node.updateRatio(for: pane1.id, newRatio: 0.7)
        if case .split(_, let ratio, _, _) = result {
            #expect(ratio == 0.7)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updateRatioSecondChildInverts() {
        // newRatio is the target pane's share. When the target is the second
        // child, the parent's stored ratio (first child's share) becomes
        // 1 - newRatio so the target ends up at `newRatio`.
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        let result = node.updateRatio(for: pane2.id, newRatio: 0.2)
        if case .split(_, let ratio, _, _) = result {
            #expect(abs(ratio - 0.8) < 0.0001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func updateRatioNestedChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()

        // Structure: split(vert, leaf(pane1), split(horiz, leaf(pane2), leaf(pane3)))
        let inner = PaneNode.split(direction: .horizontal, ratio: 0.5, first: .leaf(pane2), second: .leaf(pane3))
        let node = PaneNode.split(direction: .vertical, ratio: 0.5, first: .leaf(pane1), second: inner)

        // Update ratio of the inner split via pane2.
        let result = node.updateRatio(for: pane2.id, newRatio: 0.3)

        // Outer ratio unchanged.
        if case .split(_, let outerRatio, _, let secondChild) = result {
            #expect(outerRatio == 0.5)
            // Inner ratio updated.
            if case .split(_, let innerRatio, _, _) = secondChild {
                #expect(innerRatio == 0.3)
            } else {
                Issue.record("Expected inner split node")
            }
        } else {
            Issue.record("Expected outer split node")
        }
    }

    // MARK: - Resize

    @Test func resizeFirstChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        // Grow first child: ratio increases.
        let result = node.resizePane(id: pane1.id, delta: 0.1)
        #expect(result != nil)
        if case .split(_, let ratio, _, _) = result! {
            #expect(abs(ratio - 0.6) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizeSecondChild() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        // Grow second child: ratio decreases.
        let result = node.resizePane(id: pane2.id, delta: 0.1)
        #expect(result != nil)
        if case .split(_, let ratio, _, _) = result! {
            #expect(abs(ratio - 0.4) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizeClampsToMin() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.15,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        // Shrink first child below minimum: clamped to 0.1.
        let result = node.resizePane(id: pane1.id, delta: -0.1)
        #expect(result != nil)
        if case .split(_, let ratio, _, _) = result! {
            #expect(abs(ratio - 0.1) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizeClampsToMax() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.85,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        // Grow first child beyond maximum: clamped to 0.9.
        let result = node.resizePane(id: pane1.id, delta: 0.1)
        #expect(result != nil)
        if case .split(_, let ratio, _, _) = result! {
            #expect(abs(ratio - 0.9) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizeNestedPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()

        let inner = PaneNode.split(direction: .horizontal, ratio: 0.5, first: .leaf(pane2), second: .leaf(pane3))
        let node = PaneNode.split(direction: .vertical, ratio: 0.5, first: .leaf(pane1), second: inner)

        // Resize pane2 (inner first child).
        let result = node.resizePane(id: pane2.id, delta: 0.1)
        #expect(result != nil)
        if case .split(_, let outerRatio, _, let secondChild) = result! {
            #expect(abs(outerRatio - 0.5) < 0.001)  // Outer unchanged.
            if case .split(_, let innerRatio, _, _) = secondChild {
                #expect(abs(innerRatio - 0.6) < 0.001)  // Inner grew.
            } else {
                Issue.record("Expected inner split node")
            }
        } else {
            Issue.record("Expected outer split node")
        }
    }

    @Test func resizeLeafReturnsNil() {
        let pane = TerminalPane()
        let node = PaneNode.leaf(pane)
        #expect(node.resizePane(id: pane.id, delta: 0.1) == nil)
    }

    @Test func resizeNonExistentReturnsNil() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )
        #expect(node.resizePane(id: UUID(), delta: 0.1) == nil)
    }

    // MARK: - Replace

    @Test func replacingPane() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let paneNew = TerminalPane()
        let node = PaneNode.split(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(pane1),
            second: .leaf(pane2)
        )

        let result = node.replacingPane(id: pane1.id, with: .leaf(paneNew))
        #expect(result.allPaneIDs == [paneNew.id, pane2.id])
    }

    // MARK: - TerminalTab Integration

    @Test func terminalTabAllPaneIDs() {
        let tab = TerminalTab(title: "test")
        #expect(tab.allPaneIDs.count == 1)
        #expect(tab.paneTree.rootPane != nil)
    }
}
