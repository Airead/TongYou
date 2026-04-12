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
    @State private var focusManager = FocusManager()

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
                    focusManager: focusManager,
                    onTabAction: handleTabAction,
                    onTitleChanged: { title in
                        tabManager.updateTitle(title, for: activeTab.id)
                    },
                    onNodeChanged: { newTree in
                        tabManager.updateActivePaneTree(newTree)
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
        let cwd: String? = focusedPaneCWD
        tabManager.createTab(initialWorkingDirectory: cwd)
        // Focus the new tab's root pane.
        if let newTab = tabManager.activeTab {
            focusManager.focusPane(id: newTab.paneTree.firstPane.id)
        }
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
        } else if let activeTab = tabManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    private func switchToTab(at index: Int) {
        tabManager.selectTab(at: index)
        if let activeTab = tabManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    // MARK: - Pane Operations

    private func splitPane(direction: SplitDirection) {
        guard let focusedID = focusManager.focusedPaneID else { return }
        let cwd = viewStore.view(for: focusedID)?.currentWorkingDirectory
        let newPane = TerminalPane(initialWorkingDirectory: cwd)
        guard tabManager.splitPane(id: focusedID, direction: direction, newPane: newPane) else {
            return
        }
        focusManager.focusPane(id: newPane.id)
    }

    private func closePane() {
        guard let focusedID = focusManager.focusedPaneID else { return }
        removePane(id: focusedID)
    }

    /// Tear down a pane and focus the nearest sibling or close the tab/window.
    private func removePane(id paneID: UUID) {
        viewStore.tearDown(for: paneID)

        if let siblingID = tabManager.closePane(id: paneID) {
            focusManager.focusPane(id: siblingID)
            if let metalView = viewStore.view(for: siblingID) {
                metalView.window?.makeFirstResponder(metalView)
            }
        } else if tabManager.tabs.isEmpty {
            NSApp.keyWindow?.close()
        } else if let activeTab = tabManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    // MARK: - Action Dispatch

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
        case .splitVertical:
            splitPane(direction: .vertical)
        case .splitHorizontal:
            splitPane(direction: .horizontal)
        case .closePane:
            closePane()
        case .focusPane(let direction):
            moveFocus(direction)
        case .paneExited(let paneID):
            removePane(id: paneID)
        }
    }

    private func moveFocus(_ direction: FocusDirection) {
        guard let activeTab = tabManager.activeTab else { return }
        focusManager.moveFocus(direction: direction, in: activeTab.paneTree)
        // Make the focused MetalView first responder so it receives keyboard input.
        if let focusedID = focusManager.focusedPaneID,
           let metalView = viewStore.view(for: focusedID) {
            metalView.window?.makeFirstResponder(metalView)
        }
    }

    // MARK: - Helpers

    /// Get the CWD from the currently focused pane.
    private var focusedPaneCWD: String? {
        guard let focusedID = focusManager.focusedPaneID else {
            return tabManager.activeTab.flatMap { tab in
                viewStore.view(for: tab.paneTree.firstPane.id)?.currentWorkingDirectory
            }
        }
        return viewStore.view(for: focusedID)?.currentWorkingDirectory
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
