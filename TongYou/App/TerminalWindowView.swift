import SwiftUI

/// Root view for a terminal window, managing tabs and the active terminal view.
///
/// Structure:
/// ```
/// TerminalWindowView
///   +-- TabBarView (visible when tab count > 1, or configured)
///   +-- PaneSplitView (active tab's pane tree)
/// ```
struct TerminalWindowView: View {

    @State private var tabManager = TabManager()
    @State private var tabBarVisibility: TabBarVisibility = .auto

    /// Stores MetalView instances outside of SwiftUI state so that
    /// NSViewRepresentable.makeNSView can read/write without triggering
    /// "Modifying state during view update" warnings.
    @State private var viewStore = MetalViewStore()

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowTabBar {
                TabBarView(
                    tabs: tabManager.tabs,
                    activeTabIndex: tabManager.activeTabIndex,
                    onSelect: { index in
                        switchToTab(at: index)
                    },
                    onClose: { index in
                        closeTab(at: index)
                    },
                    onNew: {
                        createNewTab()
                    },
                    onMove: { from, to in
                        tabManager.moveTab(from: from, to: to)
                    }
                )
            }

            if let activeTab = tabManager.activeTab {
                PaneSplitView(
                    node: activeTab.paneTree,
                    viewStore: viewStore,
                    onTabAction: handleTabAction,
                    onTitleChanged: { title in
                        tabManager.updateTitle(title, for: activeTab.id)
                    }
                )
                .id(activeTab.id)
            }
        }
        .onAppear {
            if tabManager.tabs.isEmpty {
                createNewTab()
            }
        }
    }

    private var shouldShowTabBar: Bool {
        switch tabBarVisibility {
        case .auto: tabManager.count > 1
        case .always: true
        case .never: false
        }
    }

    // MARK: - Tab Operations

    private func createNewTab() {
        let cwd: String? = tabManager.activeTab.flatMap { tab in
            viewStore.view(for: tab.paneTree.firstPane.id)?.currentWorkingDirectory
        }
        tabManager.createTab(initialWorkingDirectory: cwd)
    }

    private func closeTab(at index: Int) {
        guard tabManager.tabs.indices.contains(index) else { return }
        let tab = tabManager.tabs[index]

        // Tear down all MetalViews in this tab's pane tree.
        for paneID in tab.allPaneIDs {
            viewStore.tearDown(for: paneID)
        }

        tabManager.closeTab(at: index)

        if tabManager.tabs.isEmpty {
            NSApp.keyWindow?.close()
        }
    }

    private func switchToTab(at index: Int) {
        tabManager.selectTab(at: index)
    }

    private func handleTabAction(_ action: TabAction) {
        switch action {
        case .newTab:
            createNewTab()
        case .closeTab:
            closeTab(at: tabManager.activeTabIndex)
        case .previousTab:
            tabManager.selectPreviousTab()
        case .nextTab:
            tabManager.selectNextTab()
        case .gotoTab(let n):
            tabManager.selectTabByNumber(n)
        }
    }
}

// MARK: - MetalView Store

/// Plain reference type that holds MetalView instances keyed by pane ID.
/// Not `@Observable` — invisible to SwiftUI, so mutations in `makeNSView`
/// do not trigger "Modifying state during view update" warnings.
final class MetalViewStore {
    private var views: [UUID: MetalView] = [:]

    func view(for paneID: UUID) -> MetalView? {
        views[paneID]
    }

    func store(_ view: MetalView, for paneID: UUID) {
        views[paneID] = view
    }

    func tearDown(for paneID: UUID) {
        if let view = views.removeValue(forKey: paneID) {
            view.tearDown()
        }
    }
}
