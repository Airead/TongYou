import CoreGraphics
import Foundation
import TYTerminal

/// Actions communicated from MetalView up to the window for dispatch.
enum TabAction: Equatable {
    // Session management
    case newSession
    case closeSession
    case previousSession
    case nextSession
    case toggleSidebar
    // Tab management
    case newTab
    case closeTab
    case previousTab
    case nextTab
    case gotoTab(Int)  // 1-based index
    // Pane management
    case splitVertical
    case splitHorizontal
    case closePane
    case focusPane(FocusDirection)
    case movePane(FocusDirection)
    case paneExited(UUID, exitCode: Int32)
    case growPane
    case shrinkPane
    case toggleZoom
    // Pane strategy (plan §P4.5)
    case changeStrategy(LayoutStrategyKind)
    case cycleStrategy(forward: Bool)
    // Floating pane management
    case newFloatingPane
    case closeFloatingPane(UUID)
    case toggleOrCreateFloatingPane
    case rerunFloatingPaneCommand(UUID)
    // Zombie pane (PTY exited, kept alive by close-on-exit=false). Kind-agnostic:
    // routed based on whether paneID lives in the tree or in the floating list.
    case dismissExitedPane(UUID)
    case rerunExitedPaneCommand(UUID)
    // Remote session management
    case listRemoteSessions
    case newRemoteSession
    case showSessionPicker
    case detachSession
    case renameSession
    case runInPlace(command: String, arguments: [String])
    case runCommand(command: String, arguments: [String], options: CommandOptions)
    case paneNotification(UUID, String, String)  // paneID, title, body
    // Broadcast input (sync pane typing)
    case toggleBroadcastInput
    // Clear the multi-pane selection in the active tab
    case clearPaneSelection
    // Command palette (⌘P) — opens fuzzy panel in session scope by default.
    case showCommandPalette
    // Daemon lifecycle management
    case startDaemon
    case stopDaemon
}

/// Manages the list of terminal tabs and the active tab index.
@Observable
final class TabManager {

    private(set) var tabs: [TerminalTab] = []
    private(set) var activeTabIndex: Int = 0

    /// The currently active tab, if any.
    var activeTab: TerminalTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    /// Number of tabs.
    var count: Int { tabs.count }

    // MARK: - Tab Lifecycle

    @discardableResult
    func createTab(title: String = "shell", initialWorkingDirectory: String? = nil) -> UUID {
        let tab = TerminalTab(title: title, initialWorkingDirectory: initialWorkingDirectory)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return tab.id
    }

    /// When the last tab is closed, returns true with an empty tab list
    /// — the caller is responsible for closing the window.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            return true
        }

        // Adjust active index
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }
        // If activeTabIndex == index and index is still valid, we're now
        // pointing to the tab that slid into this position — correct behavior.

        return true
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        closeTab(at: activeTabIndex)
    }

    // MARK: - Tab Switching

    func selectTab(at index: Int) {
        guard !tabs.isEmpty else { return }
        let clamped = max(0, min(index, tabs.count - 1))
        guard clamped != activeTabIndex else { return }
        activeTabIndex = clamped
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        activeTabIndex = (activeTabIndex + 1) % tabs.count
    }

    /// Cmd+9 always goes to the last tab (browser/terminal convention).
    func selectTabByNumber(_ number: Int) {
        guard !tabs.isEmpty else { return }
        if number == 9 {
            selectTab(at: tabs.count - 1)
        } else {
            selectTab(at: number - 1)
        }
    }

    // MARK: - Tab Reordering

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source),
              destination >= 0, destination < tabs.count,
              source != destination else { return }

        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)

        // Adjust active index to follow the active tab
        if activeTabIndex == source {
            activeTabIndex = destination
        } else if source < activeTabIndex && destination >= activeTabIndex {
            activeTabIndex -= 1
        } else if source > activeTabIndex && destination <= activeTabIndex {
            activeTabIndex += 1
        }
    }

    // MARK: - Pane Operations

    @discardableResult
    func splitPane(id paneID: UUID, direction: SplitDirection, newPane: TerminalPane) -> Bool {
        for i in tabs.indices {
            if let newTree = tabs[i].paneTree.split(
                paneID: paneID, direction: direction, newPane: newPane
            ) {
                tabs[i].paneTree = newTree
                return true
            }
        }
        return false
    }

    /// Close a specific pane. If it's the last pane in its tab, close the tab.
    /// Returns the ID of a sibling pane to focus, or nil if the tab was closed.
    @discardableResult
    func closePane(id paneID: UUID) -> UUID? {
        for i in tabs.indices {
            guard tabs[i].paneTree.contains(paneID: paneID) else { continue }
            if let newTree = tabs[i].paneTree.removePane(id: paneID) {
                tabs[i].paneTree = newTree
                return newTree.firstPane.id
            } else {
                closeTab(at: i)
                return nil
            }
        }
        return nil
    }

    /// Replace the active tab's pane tree (e.g. after a divider drag).
    func updateActivePaneTree(_ newTree: PaneNode) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        tabs[activeTabIndex].paneTree = newTree
    }

    // MARK: - Floating Pane Operations

    /// Mutable access to the active tab's floating panes.
    /// Callers must guard `tabs.indices.contains(activeTabIndex)` first.
    private var activeFloatingPanes: [FloatingPane] {
        get { tabs[activeTabIndex].floatingPanes }
        set { tabs[activeTabIndex].floatingPanes = newValue }
    }

    /// Create a new floating pane in the active tab.
    /// If existing floating panes overlap the default position, the new pane
    /// is cascaded (offset) so it doesn't stack directly on top.
    @discardableResult
    func createFloatingPane(initialWorkingDirectory: String? = nil) -> UUID? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        let pane = TerminalPane(initialWorkingDirectory: initialWorkingDirectory)
        let floating = FloatingPane(pane: pane, frame: activeFloatingPanes.nextCascadedFrame(), zIndex: activeFloatingPanes.nextZIndex)
        activeFloatingPanes.append(floating)
        return pane.id
    }


    /// Close a floating pane by its pane ID. Returns true if found and removed.
    /// Searches all tabs (not just active) because a PTY exit may arrive after
    /// the user has switched away from the tab that owns the floating pane.
    @discardableResult
    func closeFloatingPane(paneID: UUID) -> Bool {
        for i in tabs.indices {
            if let idx = tabs[i].floatingPanes.firstIndex(where: { $0.pane.id == paneID }) {
                tabs[i].floatingPanes.remove(at: idx)
                return true
            }
        }
        return false
    }

    /// Find the index of a floating pane by its pane ID in the active tab.
    private func activeFloatingPaneIndex(for paneID: UUID) -> Int? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return activeFloatingPanes.firstIndex(where: { $0.pane.id == paneID })
    }

    /// Bring a floating pane to the front by updating its zIndex.
    func bringFloatingPaneToFront(paneID: UUID) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        let maxZ = activeFloatingPanes.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? 0
        guard activeFloatingPanes[idx].zIndex < maxZ else { return }
        activeFloatingPanes[idx].zIndex = maxZ + 1
    }

    /// Update the normalized frame of a floating pane.
    func updateFloatingPaneFrame(paneID: UUID, frame: CGRect) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        activeFloatingPanes[idx].frame = frame
        activeFloatingPanes[idx].clampFrame()
    }

    /// Explicitly show or hide all floating panes in the active tab.
    func setFloatingPanesVisibility(visible: Bool) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        for i in activeFloatingPanes.indices {
            if activeFloatingPanes[i].isVisible != visible {
                activeFloatingPanes[i].isVisible = visible
            }
        }
    }

    /// Toggle the pinned state of a floating pane.
    func toggleFloatingPanePin(paneID: UUID) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        activeFloatingPanes[idx].isPinned.toggle()
    }

    /// Update the title of a floating pane.
    func updateFloatingPaneTitle(paneID: UUID, title: String) {
        guard let idx = activeFloatingPaneIndex(for: paneID) else { return }
        guard activeFloatingPanes[idx].title != title else { return }
        activeFloatingPanes[idx].title = title
    }

    /// Show or hide floating panes based on whether the focused pane is floating.
    /// - Focused pane is a floating pane → show all floating panes
    /// - Focused pane is a tree pane → hide all except pinned
    func updateFloatingPanesVisibilityForFocus(focusedPaneID: UUID?) {
        guard tabs.indices.contains(activeTabIndex) else { return }
        guard let focusedID = focusedPaneID else { return }

        let isFloatingFocused = activeFloatingPanes.contains { $0.pane.id == focusedID }

        for i in activeFloatingPanes.indices {
            let newVisible = isFloatingFocused || activeFloatingPanes[i].isPinned
            if activeFloatingPanes[i].isVisible != newVisible {
                activeFloatingPanes[i].isVisible = newVisible
            }
        }
    }

    // MARK: - Title Updates

    func updateTitle(_ title: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].title = title
    }

    // MARK: - Handle Action

    @discardableResult
    func handleAction(_ action: TabAction) -> Bool {
        switch action {
        case .newTab:
            createTab()
            return true
        case .closeTab:
            return closeActiveTab()
        case .previousTab:
            selectPreviousTab()
            return true
        case .nextTab:
            selectNextTab()
            return true
        case .gotoTab(let number):
            selectTabByNumber(number)
            return true
        case .newSession, .closeSession, .previousSession, .nextSession, .toggleSidebar:
            // Session actions are handled by SessionManager / TerminalWindowView.
            return false
        case .splitVertical, .splitHorizontal, .closePane,
             .focusPane, .movePane, .paneExited, .growPane, .shrinkPane, .toggleZoom,
             .changeStrategy, .cycleStrategy,
             .newFloatingPane, .closeFloatingPane, .toggleOrCreateFloatingPane,
             .rerunFloatingPaneCommand, .dismissExitedPane, .rerunExitedPaneCommand,
             .listRemoteSessions, .newRemoteSession, .showSessionPicker, .detachSession,
             .renameSession, .runInPlace, .runCommand,
             .paneNotification, .toggleBroadcastInput, .clearPaneSelection,
             .showCommandPalette, .startDaemon, .stopDaemon:
            // Pane/remote/daemon actions are handled by TerminalWindowView, not TabManager.
            return false
        }
    }
}
