import AppKit
import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("Pane Split & Focus")
struct PaneSplitTests {

    // MARK: - TabManager Split

    @Test func splitPaneVertical() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id
        let newPane = TerminalPane()

        let ok = mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: newPane)
        #expect(ok)
        #expect(mgr.activeTab!.paneTree.paneCount == 2)
        #expect(mgr.activeTab!.allPaneIDs.contains(rootPaneID))
        #expect(mgr.activeTab!.allPaneIDs.contains(newPane.id))

        if case .container(let c) = mgr.activeTab!.paneTree {
            #expect(c.strategy == .vertical)
            #expect(c.weights == [1.0, 1.0])
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func splitPaneHorizontal() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id
        let newPane = TerminalPane()

        let ok = mgr.splitPane(id: rootPaneID, direction: .horizontal, newPane: newPane)
        #expect(ok)

        if case .container(let c) = mgr.activeTab!.paneTree {
            #expect(c.strategy == .horizontal)
        } else {
            Issue.record("Expected container node")
        }
    }

    @Test func splitInvalidPaneID() {
        let mgr = TabManager()
        mgr.createTab(title: "test")

        let ok = mgr.splitPane(id: UUID(), direction: .vertical, newPane: TerminalPane())
        #expect(!ok)
        #expect(mgr.activeTab!.paneTree.paneCount == 1)
    }

    @Test func splitNestedPane() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id

        // First split
        let pane2 = TerminalPane()
        mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: pane2)
        // Split the second pane again
        let pane3 = TerminalPane()
        let ok = mgr.splitPane(id: pane2.id, direction: .horizontal, newPane: pane3)

        #expect(ok)
        #expect(mgr.activeTab!.paneTree.paneCount == 3)
    }

    // MARK: - TabManager Close Pane

    @Test func closePanePromotesSibling() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id
        let newPane = TerminalPane()
        mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: newPane)

        // Close the new pane; original should be promoted.
        let siblingID = mgr.closePane(id: newPane.id)
        #expect(siblingID == rootPaneID)
        #expect(mgr.activeTab!.paneTree.paneCount == 1)
        #expect(mgr.activeTab!.paneTree.rootPane?.id == rootPaneID)
    }

    @Test func closeLastPaneClosesTab() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id

        let result = mgr.closePane(id: rootPaneID)
        #expect(result == nil)
        #expect(mgr.tabs.isEmpty)
    }

    @Test func closePaneInNestedSplit() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let pane1ID = mgr.activeTab!.paneTree.firstPane.id
        let pane2 = TerminalPane()
        mgr.splitPane(id: pane1ID, direction: .vertical, newPane: pane2)
        let pane3 = TerminalPane()
        mgr.splitPane(id: pane2.id, direction: .horizontal, newPane: pane3)

        // Close pane3 — pane2 promoted in inner split.
        let siblingID = mgr.closePane(id: pane3.id)
        #expect(siblingID != nil)
        #expect(mgr.activeTab!.paneTree.paneCount == 2)
        #expect(mgr.activeTab!.allPaneIDs.contains(pane1ID))
        #expect(mgr.activeTab!.allPaneIDs.contains(pane2.id))
    }

    // MARK: - TabManager Update Ratio

    @Test func updateActivePaneTree() {
        let mgr = TabManager()
        mgr.createTab(title: "test")
        let rootPaneID = mgr.activeTab!.paneTree.firstPane.id
        let newPane = TerminalPane()
        mgr.splitPane(id: rootPaneID, direction: .vertical, newPane: newPane)

        // Simulate divider drag: update weights via tree replacement.
        if case .container(let c) = mgr.activeTab!.paneTree {
            let updated = PaneNode.container(Container(
                id: c.id,
                strategy: c.strategy,
                children: c.children,
                weights: [0.7, 0.3]
            ))
            mgr.updateActivePaneTree(updated)
        }

        if case .container(let c) = mgr.activeTab!.paneTree {
            #expect(c.weights == [0.7, 0.3])
        } else {
            Issue.record("Expected container node")
        }
    }

    // MARK: - FocusManager

    @Test func focusPane() {
        let fm = FocusManager()
        let id = UUID()

        fm.focusPane(id: id)
        #expect(fm.focusedPaneID == id)

        // Same ID is no-op.
        fm.focusPane(id: id)
        #expect(fm.focusedPaneID == id)
    }

    @Test func clearFocus() {
        let fm = FocusManager()
        fm.focusPane(id: UUID())
        fm.clearFocus()
        #expect(fm.focusedPaneID == nil)
    }

    // MARK: - Focus Navigation

    @Test func moveFocusInSimpleSplit() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let tree = PaneNode.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        ))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Move right: pane1 → pane2
        fm.moveFocus(direction: .right, in: tree)
        #expect(fm.focusedPaneID == pane2.id)

        // Move left: pane2 → pane1
        fm.moveFocus(direction: .left, in: tree)
        #expect(fm.focusedPaneID == pane1.id)

        // Move left at boundary: stays at pane1
        fm.moveFocus(direction: .left, in: tree)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusVerticalSplit() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let tree = PaneNode.container(Container(
            strategy: .horizontal,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        ))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Move down: pane1 → pane2
        fm.moveFocus(direction: .down, in: tree)
        #expect(fm.focusedPaneID == pane2.id)

        // Move up: pane2 → pane1
        fm.moveFocus(direction: .up, in: tree)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusCrossAxis() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let tree = PaneNode.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        ))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Moving up/down in a vertical split — no neighbor.
        fm.moveFocus(direction: .up, in: tree)
        #expect(fm.focusedPaneID == pane1.id)

        fm.moveFocus(direction: .down, in: tree)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusNestedSplit() {
        // Layout: split(vert, pane1, split(horiz, pane2, pane3))
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let pane3 = TerminalPane()
        let inner = PaneNode.container(Container(
            strategy: .horizontal,
            children: [.leaf(pane2), .leaf(pane3)],
            weights: [1.0, 1.0]
        ))
        let tree = PaneNode.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), inner],
            weights: [1.0, 1.0]
        ))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Right from pane1 → enters right subtree, top pane (pane2)
        fm.moveFocus(direction: .right, in: tree)
        #expect(fm.focusedPaneID == pane2.id)

        // Down from pane2 → pane3
        fm.moveFocus(direction: .down, in: tree)
        #expect(fm.focusedPaneID == pane3.id)

        // Left from pane3 → pane1
        fm.moveFocus(direction: .left, in: tree)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusWithNoFocus() {
        let pane1 = TerminalPane()
        let tree = PaneNode.leaf(pane1)

        let fm = FocusManager()
        #expect(fm.focusedPaneID == nil)

        // Should focus the first pane.
        fm.moveFocus(direction: .right, in: tree)
        #expect(fm.focusedPaneID == pane1.id)
    }

    // MARK: - Keybinding Normalization

    @Test func arrowKeyScalarsNormalizeToNames() {
        // macOS reports arrow keys as private-use Unicode scalars via
        // `charactersIgnoringModifiers`. They must be translated to the
        // readable names keybinding configs use, otherwise
        // `cmd+option+<arrow>` bindings never match.
        #expect(Keybinding.normalizedKey(from: "\u{F700}") == "up")
        #expect(Keybinding.normalizedKey(from: "\u{F701}") == "down")
        #expect(Keybinding.normalizedKey(from: "\u{F702}") == "left")
        #expect(Keybinding.normalizedKey(from: "\u{F703}") == "right")
        // Ordinary characters must pass through unchanged.
        #expect(Keybinding.normalizedKey(from: "a") == "a")
        #expect(Keybinding.normalizedKey(from: "left") == "left")
    }

    @Test func modifierMaskStripsFunctionAndNumpadBits() {
        // Arrow keys arrive with `.function` (and often `.numericPad`) set
        // alongside the user-pressed modifiers. Strict equality against a
        // binding declared as `[.command, .option]` fails unless we first
        // mask down to the modifiers configs actually care about.
        let arrowKeyFlags: NSEvent.ModifierFlags = [.command, .option, .function, .numericPad]
        let masked = arrowKeyFlags.intersection(.relevantFlags)
        #expect(masked == [.command, .option])

        // `.relevantFlags` itself must not include the extraneous bits.
        #expect(!NSEvent.ModifierFlags.relevantFlags.contains(.function))
        #expect(!NSEvent.ModifierFlags.relevantFlags.contains(.numericPad))
        #expect(NSEvent.ModifierFlags.relevantFlags.contains(.command))
        #expect(NSEvent.ModifierFlags.relevantFlags.contains(.option))
    }

    // MARK: - Keybinding Action Parsing

    @Test func paneActionRawValueRoundTrip() {
        let actions: [Keybinding.Action] = [
            .splitVertical, .splitHorizontal, .closePane,
            .focusPane(.left), .focusPane(.right), .focusPane(.up), .focusPane(.down),
        ]
        for action in actions {
            let parsed = Keybinding.Action(rawValue: action.rawValue)
            #expect(parsed == action, "Round-trip failed for \(action.rawValue)")
        }
    }
}
