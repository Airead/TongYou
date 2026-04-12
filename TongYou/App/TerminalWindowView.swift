import SwiftUI

/// Root view for a terminal window, managing tabs and the active terminal view.
///
/// Structure:
/// ```
/// TerminalWindowView
///   +-- TabBarView (visible when tab count > 1, or configured)
///   +-- ZStack
///       +-- PaneSplitView (active tab's pane tree)
///       +-- FloatingPaneOverlay (floating panes sorted by z-order)
/// ```
struct TerminalWindowView: View {

    @State private var tabManager = TabManager()
    @State private var tabBarVisibility: TabBarVisibility = .auto
    @State private var focusManager = FocusManager()
    @State private var windowBackgroundColor: NSColor = .black

    /// Stores MetalView instances outside of SwiftUI state so that
    /// NSViewRepresentable.makeNSView can read/write without triggering
    /// "Modifying state during view update" warnings.
    @State private var viewStore = MetalViewStore()

    /// Loads config to derive the window background color.
    /// Each MetalView also has its own ConfigLoader for rendering.
    @State private var configLoader = ConfigLoader()

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
                let updateTabTitle: (String) -> Void = { title in
                    tabManager.updateTitle(title, for: activeTab.id)
                }

                ZStack {
                    PaneSplitView(
                        node: activeTab.paneTree,
                        viewStore: viewStore,
                        focusManager: focusManager,
                        onTabAction: handleTabAction,
                        onTitleChanged: updateTabTitle,
                        onNodeChanged: { newTree in
                            tabManager.updateActivePaneTree(newTree)
                        }
                    )

                    FloatingPaneOverlay(
                        floatingPanes: activeTab.floatingPanes,
                        viewStore: viewStore,
                        focusManager: focusManager,
                        onTabAction: handleTabAction,
                        onTitleChanged: { paneID, title in
                            tabManager.updateFloatingPaneTitle(paneID: paneID, title: title)
                        },
                        onFrameChanged: { paneID, frame in
                            tabManager.updateFloatingPaneFrame(paneID: paneID, frame: frame)
                        },
                        onBringToFront: { paneID in
                            tabManager.bringFloatingPaneToFront(paneID: paneID)
                        },
                        onClose: { paneID in
                            closeFloatingPane(id: paneID)
                        },
                        onTogglePin: { paneID in
                            tabManager.toggleFloatingPanePin(paneID: paneID)
                        }
                    )
                }
                .id(activeTab.id)
            }
        }
        .background(WindowConfigurator(backgroundColor: windowBackgroundColor))
        .onAppear {
            if tabManager.tabs.isEmpty {
                createNewTab()
            }
            loadWindowBackground()
        }
        .onChange(of: focusManager.focusedPaneID) { _, newID in
            tabManager.updateFloatingPanesVisibilityForFocus(focusedPaneID: newID)
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

        // Tear down all MetalViews in this tab's pane tree and floating panes.
        for paneID in tab.allPaneIDsIncludingFloating {
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
        // Check if this is a floating pane first.
        if tabManager.activeTab?.floatingPanes.contains(where: { $0.pane.id == paneID }) == true {
            closeFloatingPane(id: paneID)
            return
        }

        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)

        if let siblingID = tabManager.closePane(id: paneID) {
            focusNextPane(fallback: siblingID)
        } else if tabManager.tabs.isEmpty {
            NSApp.keyWindow?.close()
        } else if let activeTab = tabManager.activeTab {
            focusManager.focusPane(id: activeTab.paneTree.firstPane.id)
        }
    }

    // MARK: - Floating Pane Operations

    private func createFloatingPane() {
        let cwd = focusedPaneCWD
        guard let paneID = tabManager.createFloatingPane(initialWorkingDirectory: cwd) else { return }
        focusManager.focusPane(id: paneID)
    }

    /// Toggle floating panes visibility, or create one if none exist.
    private func toggleOrCreateFloatingPane() {
        guard let activeTab = tabManager.activeTab else { return }
        if activeTab.floatingPanes.isEmpty {
            createFloatingPane()
            return
        }

        let floatingIDs = Set(activeTab.floatingPanes.map(\.pane.id))
        let isFocusingFloat = focusManager.focusedPaneID.map(floatingIDs.contains) ?? false

        if isFocusingFloat {
            // Currently on a floating pane → hide and return to previous tree pane
            tabManager.setFloatingPanesVisibility(visible: false)
            let treeIDs = Set(activeTab.allPaneIDs)
            let targetID = focusManager.previousFocusedPane(existingIn: treeIDs)
                ?? activeTab.paneTree.firstPane.id
            focusAndActivate(paneID: targetID)
        } else {
            // Currently on a tree pane → show all and focus floating
            tabManager.setFloatingPanesVisibility(visible: true)
            let targetID = focusManager.previousFocusedPane(existingIn: floatingIDs)
                ?? activeTab.floatingPanes.last?.pane.id
            if let id = targetID {
                focusAndActivate(paneID: id)
            }
        }
    }

    private func closeFloatingPane(id paneID: UUID) {
        viewStore.tearDown(for: paneID)
        focusManager.removeFromHistory(id: paneID)
        tabManager.closeFloatingPane(paneID: paneID)

        if let activeTab = tabManager.activeTab {
            focusNextPane(fallback: activeTab.paneTree.firstPane.id)
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
        case .newFloatingPane:
            createFloatingPane()
        case .closeFloatingPane(let paneID):
            closeFloatingPane(id: paneID)
        case .toggleOrCreateFloatingPane:
            toggleOrCreateFloatingPane()
        }
    }

    private func moveFocus(_ direction: FocusDirection) {
        guard let activeTab = tabManager.activeTab else { return }
        focusManager.moveFocus(direction: direction, in: activeTab.paneTree)
        if let focusedID = focusManager.focusedPaneID {
            activateFirstResponder(for: focusedID)
        }
    }

    // MARK: - Helpers

    /// Pick the best pane to focus after closing one: prefer focus history, fall back to `fallback`.
    private func focusNextPane(fallback: UUID) {
        let remaining = Set(tabManager.activeTab?.allPaneIDsIncludingFloating ?? [])
        let nextID = focusManager.previousFocusedPane(existingIn: remaining) ?? fallback
        focusAndActivate(paneID: nextID)
    }

    /// Focus a pane and make its MetalView the first responder for keyboard input.
    private func focusAndActivate(paneID: UUID) {
        focusManager.focusPane(id: paneID)
        activateFirstResponder(for: paneID)
    }

    private func activateFirstResponder(for paneID: UUID) {
        if let metalView = viewStore.view(for: paneID) {
            metalView.window?.makeFirstResponder(metalView)
        }
    }

    /// Load config and derive window background color, with hot-reload support.
    private func loadWindowBackground() {
        configLoader.load()
        windowBackgroundColor = configLoader.config.background.nsColor
        configLoader.onConfigChanged = { newConfig in
            windowBackgroundColor = newConfig.background.nsColor
        }
    }

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

// MARK: - RGBColor + AppKit

extension RGBColor {
    var nsColor: NSColor {
        NSColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}

// MARK: - Window Configurator

/// Sets the hosting NSWindow's titlebar to transparent and background color
/// to match the terminal theme, so the title bar blends with the content.
struct WindowConfigurator: NSViewRepresentable {
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = backgroundColor
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
