import Foundation
import Testing
@testable import TongYou

@MainActor
@Suite("PaneSelectionManager")
struct PaneSelectionManagerTests {

    // MARK: - Toggle per pane

    @Test func togglePaneAddsAndRemoves() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let paneA = UUID()
        let paneB = UUID()

        mgr.togglePane(paneA, inTab: tabID)
        mgr.togglePane(paneB, inTab: tabID)
        #expect(mgr.isSelected(pane: paneA, inTab: tabID))
        #expect(mgr.isSelected(pane: paneB, inTab: tabID))

        mgr.togglePane(paneA, inTab: tabID)
        #expect(!mgr.isSelected(pane: paneA, inTab: tabID))
        #expect(mgr.isSelected(pane: paneB, inTab: tabID))
    }

    @Test func togglingLastPaneClearsSelection() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let pane = UUID()

        mgr.togglePane(pane, inTab: tabID)
        mgr.togglePane(pane, inTab: tabID)

        // No lingering empty set — the tab key is removed entirely.
        #expect(mgr.selection(inTab: tabID).isEmpty)
    }

    @Test func selectionIsolatedPerTab() {
        let mgr = PaneSelectionManager()
        let tabA = UUID()
        let tabB = UUID()
        let pane = UUID()

        mgr.togglePane(pane, inTab: tabA)
        #expect(mgr.isSelected(pane: pane, inTab: tabA))
        #expect(!mgr.isSelected(pane: pane, inTab: tabB))
    }

    // MARK: - Broadcast toggle

    @Test func toggleBroadcastAutoSelectsAllPanes() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let panes = [UUID(), UUID(), UUID()]

        let result = mgr.toggleBroadcast(tab: tabID, candidatePanes: panes)

        #expect(result == .enabled)
        #expect(mgr.isBroadcasting(tab: tabID))
        #expect(mgr.selection(inTab: tabID) == Set(panes))
    }

    @Test func toggleBroadcastWithExistingSelectionKeepsIt() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()

        mgr.togglePane(paneA, inTab: tabID)
        mgr.togglePane(paneB, inTab: tabID)

        let result = mgr.toggleBroadcast(tab: tabID, candidatePanes: [paneA, paneB, paneC])

        #expect(result == .enabled)
        #expect(mgr.selection(inTab: tabID) == [paneA, paneB])
    }

    @Test func toggleBroadcastOffRetainsSelection() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let panes = [UUID(), UUID()]

        _ = mgr.toggleBroadcast(tab: tabID, candidatePanes: panes)
        let result = mgr.toggleBroadcast(tab: tabID, candidatePanes: panes)

        #expect(result == .disabled)
        #expect(!mgr.isBroadcasting(tab: tabID))
        #expect(mgr.selection(inTab: tabID) == Set(panes))
    }

    @Test func toggleBroadcastRejectsSinglePaneTab() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let pane = UUID()

        let result = mgr.toggleBroadcast(tab: tabID, candidatePanes: [pane])

        #expect(result == .rejectedTooFewPanes)
        #expect(!mgr.isBroadcasting(tab: tabID))
        #expect(mgr.selection(inTab: tabID).isEmpty)
    }

    @Test func broadcastTargetsOnlyWhenSourceInSelection() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let inGroup = [UUID(), UUID()]
        let outsider = UUID()

        _ = mgr.toggleBroadcast(tab: tabID, candidatePanes: inGroup)

        #expect(mgr.broadcastTargets(from: inGroup[0], inTab: tabID) == Set(inGroup))
        #expect(mgr.broadcastTargets(from: outsider, inTab: tabID) == nil)
    }

    @Test func broadcastTargetsNilWhenNotBroadcasting() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let panes = [UUID(), UUID()]

        mgr.togglePane(panes[0], inTab: tabID)
        mgr.togglePane(panes[1], inTab: tabID)

        #expect(mgr.broadcastTargets(from: panes[0], inTab: tabID) == nil)
    }

    // MARK: - Cleanup

    @Test func didRemovePaneDropsFromEveryTab() {
        let mgr = PaneSelectionManager()
        let tabA = UUID()
        let tabB = UUID()
        let pane = UUID()
        let otherA = UUID()
        let otherB = UUID()

        mgr.togglePane(pane, inTab: tabA)
        mgr.togglePane(otherA, inTab: tabA)
        mgr.togglePane(pane, inTab: tabB)
        mgr.togglePane(otherB, inTab: tabB)

        mgr.didRemovePane(pane)

        #expect(!mgr.isSelected(pane: pane, inTab: tabA))
        #expect(!mgr.isSelected(pane: pane, inTab: tabB))
        #expect(mgr.isSelected(pane: otherA, inTab: tabA))
        #expect(mgr.isSelected(pane: otherB, inTab: tabB))
    }

    @Test func didRemovePaneDisablesBroadcastWhenSelectionEmpties() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let paneA = UUID()
        let paneB = UUID()

        _ = mgr.toggleBroadcast(tab: tabID, candidatePanes: [paneA, paneB])
        #expect(mgr.isBroadcasting(tab: tabID))

        mgr.didRemovePane(paneA)
        mgr.didRemovePane(paneB)

        #expect(!mgr.isBroadcasting(tab: tabID))
        #expect(mgr.selection(inTab: tabID).isEmpty)
    }

    @Test func didRemoveTabForgetsState() {
        let mgr = PaneSelectionManager()
        let tabID = UUID()
        let panes = [UUID(), UUID()]

        _ = mgr.toggleBroadcast(tab: tabID, candidatePanes: panes)
        mgr.didRemoveTab(tabID)

        #expect(!mgr.isBroadcasting(tab: tabID))
        #expect(mgr.selection(inTab: tabID).isEmpty)
    }
}
