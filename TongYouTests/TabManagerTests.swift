import Foundation
import Testing
@testable import TongYou

@Suite("TabManager")
struct TabManagerTests {

    // MARK: - Creation

    @Test func createFirstTab() {
        let mgr = TabManager()
        let id = mgr.createTab(title: "zsh")
        #expect(mgr.count == 1)
        #expect(mgr.activeTabIndex == 0)
        #expect(mgr.activeTab?.id == id)
        #expect(mgr.activeTab?.title == "zsh")
    }

    @Test func createMultipleTabs() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")
        let id3 = mgr.createTab(title: "tab3")

        #expect(mgr.count == 3)
        // New tab should be active
        #expect(mgr.activeTabIndex == 2)
        #expect(mgr.activeTab?.id == id3)
        #expect(mgr.tabs[0].id == id1)
    }

    // MARK: - Close

    @Test func closeActiveTab() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "tab1")
        let id2 = mgr.createTab(title: "tab2")
        _ = mgr.createTab(title: "tab3")

        // Active is tab3 (index 2)
        mgr.selectTab(at: 1)  // Switch to tab2
        #expect(mgr.activeTab?.id == id2)

        let closed = mgr.closeActiveTab()
        #expect(closed)
        #expect(mgr.count == 2)
        // After closing index 1, the tab that was at index 2 slides to index 1
        #expect(mgr.activeTabIndex == 1)
        #expect(mgr.activeTab?.title == "tab3")
    }

    @Test func closeFirstTab() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "tab1")
        let id2 = mgr.createTab(title: "tab2")

        mgr.selectTab(at: 0)
        mgr.closeTab(at: 0)

        #expect(mgr.count == 1)
        #expect(mgr.activeTabIndex == 0)
        #expect(mgr.activeTab?.id == id2)
    }

    @Test func closeLastRemainingTab() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "only")

        let closed = mgr.closeActiveTab()
        #expect(closed)
        #expect(mgr.count == 0)
        #expect(mgr.activeTab == nil)
    }

    @Test func closeTabBeforeActive() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")
        let id3 = mgr.createTab(title: "tab3")

        // Active is tab3 (index 2)
        mgr.closeTab(at: 0)

        #expect(mgr.count == 2)
        // Active was at 2, removed before it, so it shifts to 1
        #expect(mgr.activeTabIndex == 1)
        #expect(mgr.activeTab?.id == id3)
    }

    @Test func closeTabAfterActive() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")
        _ = mgr.createTab(title: "tab3")

        mgr.selectTab(at: 0)
        mgr.closeTab(at: 2)

        #expect(mgr.count == 2)
        #expect(mgr.activeTabIndex == 0)
        #expect(mgr.activeTab?.id == id1)
    }

    @Test func closeInvalidIndex() {
        let mgr = TabManager()
        _ = mgr.createTab()

        #expect(!mgr.closeTab(at: 5))
        #expect(!mgr.closeTab(at: -1))
        #expect(mgr.count == 1)
    }

    // MARK: - Switching

    @Test func selectTab() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")

        mgr.selectTab(at: 0)
        #expect(mgr.activeTabIndex == 0)
        #expect(mgr.activeTab?.id == id1)
    }

    @Test func selectTabClamped() {
        let mgr = TabManager()
        _ = mgr.createTab()
        _ = mgr.createTab()

        mgr.selectTab(at: 100)
        #expect(mgr.activeTabIndex == 1)

        mgr.selectTab(at: -5)
        #expect(mgr.activeTabIndex == 0)
    }

    @Test func previousTabWraps() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")
        _ = mgr.createTab(title: "tab3")

        mgr.selectTab(at: 0)
        mgr.selectPreviousTab()

        #expect(mgr.activeTabIndex == 2)
    }

    @Test func nextTabWraps() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")

        // Active is tab2 (index 1)
        mgr.selectNextTab()
        #expect(mgr.activeTabIndex == 0)
    }

    @Test func previousAndNextNoOpWithSingleTab() {
        let mgr = TabManager()
        _ = mgr.createTab()

        mgr.selectPreviousTab()
        #expect(mgr.activeTabIndex == 0)

        mgr.selectNextTab()
        #expect(mgr.activeTabIndex == 0)
    }

    @Test func gotoTabByNumber() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")
        let id3 = mgr.createTab(title: "tab3")

        mgr.selectTabByNumber(1)
        #expect(mgr.activeTab?.id == id1)

        // Cmd+9 always goes to last
        mgr.selectTabByNumber(9)
        #expect(mgr.activeTab?.id == id3)
    }

    @Test func gotoTabOutOfRange() {
        let mgr = TabManager()
        _ = mgr.createTab()
        _ = mgr.createTab()

        // Cmd+5 with only 2 tabs: clamp to last
        mgr.selectTabByNumber(5)
        #expect(mgr.activeTabIndex == 1)
    }

    // MARK: - Reordering

    @Test func moveTab() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        let id2 = mgr.createTab(title: "tab2")
        let id3 = mgr.createTab(title: "tab3")

        // Active is tab3 (index 2)
        mgr.selectTab(at: 0)
        // Move tab1 to index 2
        mgr.moveTab(from: 0, to: 2)

        #expect(mgr.tabs[0].id == id2)
        #expect(mgr.tabs[1].id == id3)
        #expect(mgr.tabs[2].id == id1)
        // Active tab (id1) followed the move
        #expect(mgr.activeTabIndex == 2)
    }

    @Test func moveTabInvalid() {
        let mgr = TabManager()
        _ = mgr.createTab()

        mgr.moveTab(from: 0, to: 5)
        mgr.moveTab(from: -1, to: 0)
        mgr.moveTab(from: 0, to: 0) // same position
        #expect(mgr.count == 1)
    }

    // MARK: - Title Updates

    @Test func updateTitle() {
        let mgr = TabManager()
        let id = mgr.createTab(title: "shell")

        mgr.updateTitle("vim ~/config", for: id)
        #expect(mgr.tabs[0].title == "vim ~/config")
    }

    @Test func updateTitleUnknownID() {
        let mgr = TabManager()
        _ = mgr.createTab(title: "shell")

        mgr.updateTitle("nope", for: UUID())
        #expect(mgr.tabs[0].title == "shell")
    }

    // MARK: - handleAction

    @Test func handleActionNewTab() {
        let mgr = TabManager()
        #expect(mgr.handleAction(.newTab))
        #expect(mgr.count == 1)
    }

    @Test func handleActionCloseTab() {
        let mgr = TabManager()
        _ = mgr.createTab()
        #expect(mgr.handleAction(.closeTab))
        #expect(mgr.count == 0)
    }

    @Test func handleActionGotoTab() {
        let mgr = TabManager()
        let id1 = mgr.createTab(title: "tab1")
        _ = mgr.createTab(title: "tab2")

        #expect(mgr.handleAction(.gotoTab(1)))
        #expect(mgr.activeTab?.id == id1)
    }
}
