import SwiftUI

/// Root view for a terminal window, managing tabs and the active terminal view.
///
/// Structure:
/// ```
/// TerminalWindowView
///   +-- TabBarView (visible when tab count > 1, or configured)
///   +-- TerminalTabContainerView (active tab's MetalView)
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
                TerminalTabContainerView(
                    tabID: activeTab.id,
                    viewStore: viewStore,
                    initialWorkingDirectory: activeTab.initialWorkingDirectory,
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
        let cwd = tabManager.activeTab.flatMap { viewStore.view(for: $0.id)?.currentWorkingDirectory }
        tabManager.createTab(initialWorkingDirectory: cwd)
    }

    private func closeTab(at index: Int) {
        guard tabManager.tabs.indices.contains(index) else { return }
        let tabID = tabManager.tabs[index].id

        // Tear down the MetalView
        viewStore.tearDown(for: tabID)

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

/// Plain reference type that holds MetalView instances keyed by tab ID.
/// Not `@Observable` — invisible to SwiftUI, so mutations in `makeNSView`
/// do not trigger "Modifying state during view update" warnings.
final class MetalViewStore {
    private var views: [UUID: MetalView] = [:]

    func view(for tabID: UUID) -> MetalView? {
        views[tabID]
    }

    func store(_ view: MetalView, for tabID: UUID) {
        views[tabID] = view
    }

    func tearDown(for tabID: UUID) {
        if let view = views.removeValue(forKey: tabID) {
            view.tearDown()
        }
    }
}

// MARK: - Terminal Tab Container

/// NSViewRepresentable that manages a MetalView for a specific tab.
/// Creates the MetalView on first appearance and reuses it for subsequent displays.
struct TerminalTabContainerView: NSViewRepresentable {

    let tabID: UUID
    let viewStore: MetalViewStore
    let initialWorkingDirectory: String?
    let onTabAction: (TabAction) -> Void
    let onTitleChanged: (String) -> Void

    func makeNSView(context: Context) -> MetalView {
        if let existing = viewStore.view(for: tabID) {
            existing.onTabAction = onTabAction
            existing.onTitleChanged = onTitleChanged
            return existing
        }
        let view = MetalView()
        view.initialWorkingDirectory = initialWorkingDirectory
        view.onTabAction = onTabAction
        view.onTitleChanged = onTitleChanged
        viewStore.store(view, for: tabID)
        return view
    }

    func updateNSView(_ nsView: MetalView, context: Context) {
        nsView.onTabAction = onTabAction
        nsView.onTitleChanged = onTitleChanged
    }

    static func dismantleNSView(_ nsView: MetalView, coordinator: ()) {
        // Do NOT tear down here — the MetalView may be reused when switching tabs.
        // Tear down happens in TerminalWindowView.closeTab(at:).
    }
}
