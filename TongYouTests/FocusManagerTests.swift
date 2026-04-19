import Foundation
import Testing
import TYTerminal
@testable import TongYou

@Suite("FocusManager")
struct FocusManagerTests {

    // MARK: - Focus History Tracking

    @Test func focusPaneRecordsHistory() {
        let mgr = FocusManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id2)
        mgr.focusPane(id: id3)

        #expect(mgr.focusedPaneID == id3)
        #expect(mgr.focusHistory == [id1, id2])
    }

    @Test func focusSamePaneNoOp() {
        let mgr = FocusManager()
        let id1 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id1)

        #expect(mgr.focusedPaneID == id1)
        #expect(mgr.focusHistory.isEmpty)
    }

    @Test func focusHistoryAvoidsDuplicates() {
        let mgr = FocusManager()
        let id1 = UUID()
        let id2 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id2)
        mgr.focusPane(id: id2) // same as current, no-op

        #expect(mgr.focusHistory == [id1])
    }

    // MARK: - Remove From History

    @Test func removeFromHistoryCleansUp() {
        let mgr = FocusManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id2)
        mgr.focusPane(id: id3)

        mgr.removeFromHistory(id: id1)
        #expect(mgr.focusHistory == [id2])
    }

    @Test func removeFromHistoryNonExistent() {
        let mgr = FocusManager()
        let id1 = UUID()

        mgr.focusPane(id: id1)
        mgr.removeFromHistory(id: UUID())

        #expect(mgr.focusHistory.isEmpty)
        #expect(mgr.focusedPaneID == id1)
    }

    // MARK: - Previous Focused Pane

    @Test func previousFocusedPaneReturnsLastExisting() {
        let mgr = FocusManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id2)
        mgr.focusPane(id: id3)
        mgr.focusPane(id: id4)

        // Close id4, look for previous among remaining.
        mgr.removeFromHistory(id: id4)
        let remaining: Set<UUID> = [id1, id2, id3]
        let prev = mgr.previousFocusedPane(existingIn: remaining)
        #expect(prev == id3)
    }

    @Test func previousFocusedPaneSkipsClosed() {
        let mgr = FocusManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        mgr.focusPane(id: id1)
        mgr.focusPane(id: id2)
        mgr.focusPane(id: id3)

        // id2 is in history but no longer exists.
        let remaining: Set<UUID> = [id1]
        let prev = mgr.previousFocusedPane(existingIn: remaining)
        #expect(prev == id1)
    }

    @Test func previousFocusedPaneReturnsNilWhenEmpty() {
        let mgr = FocusManager()
        let id1 = UUID()

        mgr.focusPane(id: id1)

        let prev = mgr.previousFocusedPane(existingIn: [])
        #expect(prev == nil)
    }

    @Test func previousFocusedPaneReturnsNilNoHistory() {
        let mgr = FocusManager()
        let id1 = UUID()

        mgr.focusPane(id: id1)
        // No history yet (only one focus call).
        let prev = mgr.previousFocusedPane(existingIn: [id1])
        #expect(prev == nil)
    }

    // MARK: - Integration: Simulate Pane Close Cycle

    @Test func closePaneRestoresPreviousFocus() {
        let mgr = FocusManager()
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()

        // User focuses A, then B, then C.
        mgr.focusPane(id: paneA)
        mgr.focusPane(id: paneB)
        mgr.focusPane(id: paneC)

        // Close C → should restore to B.
        mgr.removeFromHistory(id: paneC)
        let remaining1: Set<UUID> = [paneA, paneB]
        let next1 = mgr.previousFocusedPane(existingIn: remaining1)
        #expect(next1 == paneB)

        // Simulate focus on B.
        mgr.focusPane(id: paneB)

        // Close B → should restore to A.
        mgr.removeFromHistory(id: paneB)
        let remaining2: Set<UUID> = [paneA]
        let next2 = mgr.previousFocusedPane(existingIn: remaining2)
        #expect(next2 == paneA)
    }

    @Test func closePaneWithFloatingPaneHistory() {
        let mgr = FocusManager()
        let treePaneA = UUID()
        let treePaneB = UUID()
        let floatingPane = UUID()

        // Focus: A → floating → B.
        mgr.focusPane(id: treePaneA)
        mgr.focusPane(id: floatingPane)
        mgr.focusPane(id: treePaneB)

        // Close B → should restore to floating pane (most recent in history).
        mgr.removeFromHistory(id: treePaneB)
        let remaining: Set<UUID> = [treePaneA, floatingPane]
        let next = mgr.previousFocusedPane(existingIn: remaining)
        #expect(next == floatingPane)
    }

    // MARK: - History Size Cap

    @Test func historyTruncatesAtMaxSize() {
        let mgr = FocusManager()
        // Focus 70 different panes to exceed the 64-entry cap.
        var ids: [UUID] = []
        for _ in 0..<70 {
            let id = UUID()
            ids.append(id)
            mgr.focusPane(id: id)
        }

        // History should be capped at 64 (current pane is not in history).
        #expect(mgr.focusHistory.count == 64)
        // Earliest entries should have been evicted.
        let evicted = Set(ids.prefix(5))
        for id in mgr.focusHistory {
            #expect(!evicted.contains(id))
        }
        // Most recent entries (before current) should be present.
        #expect(mgr.focusHistory.last == ids[68])
    }

    // MARK: - Move Focus Records History

    @Test func moveFocusRecordsHistory() {
        let mgr = FocusManager()
        let pane1 = TerminalPane()
        let pane2 = TerminalPane()
        let tree = PaneNode.container(Container(
            strategy: .vertical,
            children: [.leaf(pane1), .leaf(pane2)],
            weights: [1.0, 1.0]
        ))

        mgr.focusPane(id: pane1.id)
        mgr.moveFocus(direction: .right, in: tree)

        #expect(mgr.focusedPaneID == pane2.id)
        #expect(mgr.focusHistory == [pane1.id])
    }
}
