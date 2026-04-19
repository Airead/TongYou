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

    private static let focusCanvas = Rect(x: 0, y: 0, width: 100, height: 40)

    private func tab(_ tree: PaneNode) -> TerminalTab {
        TerminalTab(id: UUID(), title: "t", paneTree: tree)
    }

    @Test func moveFocusInSimpleSplit() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let t = tab(.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        )))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Move right: pane1 → pane2
        fm.moveFocus(direction: .right, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane2.id)

        // Move left: pane2 → pane1
        fm.moveFocus(direction: .left, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane1.id)

        // Move left at boundary: stays at pane1
        fm.moveFocus(direction: .left, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusVerticalSplit() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let t = tab(.container(Container(
            strategy: .horizontal,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        )))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Move down: pane1 → pane2
        fm.moveFocus(direction: .down, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane2.id)

        // Move up: pane2 → pane1
        fm.moveFocus(direction: .up, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane1.id)
    }

    @Test func moveFocusCrossAxis() {
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let t = tab(.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        )))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Moving up/down in a vertical split — no neighbor.
        fm.moveFocus(direction: .up, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane1.id)

        fm.moveFocus(direction: .down, in: t, screenRect: Self.focusCanvas)
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
        let t = tab(.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), inner],
            weights: [1.0, 1.0]
        )))

        let fm = FocusManager()
        fm.focusPane(id: pane1.id)

        // Right from pane1 → enters right subtree. With equal weights pane2
        // and pane3 each share half of pane1's height; on a tie the first
        // match in dictionary iteration wins, so just assert it's one of them.
        fm.moveFocus(direction: .right, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane2.id || fm.focusedPaneID == pane3.id)
        let landed = fm.focusedPaneID!

        // From whichever inner pane was chosen, left must return to pane1.
        fm.moveFocus(direction: .left, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == pane1.id)

        // Inner up/down still navigates between pane2 and pane3.
        fm.focusPane(id: landed)
        let opposite = (landed == pane2.id) ? pane3.id : pane2.id
        let dir: FocusDirection = (landed == pane2.id) ? .down : .up
        fm.moveFocus(direction: dir, in: t, screenRect: Self.focusCanvas)
        #expect(fm.focusedPaneID == opposite)
    }

    @Test func moveFocusWithNoFocus() {
        let pane1 = TerminalPane()
        let t = tab(.leaf(pane1))

        let fm = FocusManager()
        #expect(fm.focusedPaneID == nil)

        // Should focus the first pane.
        fm.moveFocus(direction: .right, in: t, screenRect: Self.focusCanvas)
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
            .movePane(.left), .movePane(.right), .movePane(.up), .movePane(.down),
        ]
        for action in actions {
            let parsed = Keybinding.Action(rawValue: action.rawValue)
            #expect(parsed == action, "Round-trip failed for \(action.rawValue)")
        }
    }

    @Test func defaultsBindCtrlCmdArrowsToMovePane() {
        let expected: [(String, FocusDirection)] = [
            ("left", .left), ("right", .right), ("up", .up), ("down", .down),
        ]
        for (key, dir) in expected {
            let match = Keybinding.defaults.first {
                $0.key == key
                    && $0.modifiers == [.command, .control]
                    && $0.action == .movePane(dir)
            }
            #expect(match != nil, "missing default binding Ctrl+Cmd+\(key) → movePane(\(dir))")
        }
    }

    // MARK: - ContainerLayout (2D rendering path)
    //
    // Regression coverage for the bug where `.grid` / `.masterStack` containers
    // with 2 panes rendered one pane taking almost all of the tab. Root cause
    // was `ContainerView` running them through a 1D HStack/VStack. These tests
    // exercise the pure helper that the 2D render path now feeds from.

    private func flatContainer(
        strategy: LayoutStrategyKind,
        paneCount: Int
    ) -> Container {
        Container(
            strategy: strategy,
            children: (0..<paneCount).map { _ in .leaf(TerminalPane()) },
            weights: Array(repeating: 1.0, count: paneCount)
        )
    }

    @Test func gridTwoPanesSplitEvenlySideBySide() {
        let container = flatContainer(strategy: .grid, paneCount: 2)
        let rects = ContainerLayout.rects(
            for: container,
            in: CGSize(width: 800, height: 600)
        )

        #expect(rects.count == 2)
        // 1 row × 2 columns → equal widths, full height each.
        #expect(abs(rects[0].width - rects[1].width) <= 1)
        #expect(rects[0].height == 600)
        #expect(rects[1].height == 600)
        // Neither pane should be degenerate (<10% of parent width).
        #expect(rects[0].width > 80)
        #expect(rects[1].width > 80)
        // Side-by-side, no overlap.
        #expect(rects[0].minX == 0)
        #expect(rects[1].minX >= rects[0].maxX - 1)
    }

    @Test func masterStackTwoPanesSplitEvenlyLeftRight() {
        let container = flatContainer(strategy: .masterStack, paneCount: 2)
        let rects = ContainerLayout.rects(
            for: container,
            in: CGSize(width: 800, height: 600)
        )

        #expect(rects.count == 2)
        // master weight = stack weight = 1 → 50/50 horizontally, full height.
        #expect(abs(rects[0].width - rects[1].width) <= 1)
        #expect(rects[0].height == 600)
        #expect(rects[1].height == 600)
        #expect(rects[0].width > 80)
        #expect(rects[1].width > 80)
        #expect(rects[0].minX == 0)
        #expect(rects[1].minX >= rects[0].maxX - 1)
    }

    @Test func gridFourPanesForm2x2() {
        let container = flatContainer(strategy: .grid, paneCount: 4)
        let rects = ContainerLayout.rects(
            for: container,
            in: CGSize(width: 800, height: 600)
        )

        #expect(rects.count == 4)
        // 2×2 grid: two distinct y rows, two distinct x columns.
        let ys = Set(rects.map { $0.minY })
        let xs = Set(rects.map { $0.minX })
        #expect(ys.count == 2)
        #expect(xs.count == 2)
        // All cells roughly equal area.
        let areas = rects.map { $0.width * $0.height }
        let maxArea = areas.max()!
        let minArea = areas.min()!
        #expect(minArea > 0)
        #expect(maxArea / minArea < 1.1)
    }

    @Test func masterStackThreePanesMasterPlusTwoStack() {
        let container = flatContainer(strategy: .masterStack, paneCount: 3)
        let rects = ContainerLayout.rects(
            for: container,
            in: CGSize(width: 900, height: 600)
        )

        #expect(rects.count == 3)
        // Master (index 0) runs full height; stack panes sit to its right,
        // stacked vertically with equal heights.
        #expect(rects[0].height == 600)
        #expect(rects[0].minX == 0)
        // Stack panes share the same x column, each roughly half-height.
        #expect(rects[1].minX == rects[2].minX)
        #expect(rects[1].minX >= rects[0].maxX - 1)
        #expect(abs(rects[1].height - rects[2].height) <= 1)
        #expect(rects[1].minY == 0)
        #expect(rects[2].minY >= rects[1].maxY - 1)
    }
}
