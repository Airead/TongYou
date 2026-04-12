import Foundation

/// Actions that can be performed on tabs, communicated from MetalView to the window.
enum TabAction {
    case newTab
    case closeTab
    case previousTab
    case nextTab
    case gotoTab(Int)  // 1-based index
}

/// A single terminal tab containing a tree of panes.
struct TerminalTab: Identifiable {
    let id: UUID
    var title: String
    var paneTree: PaneNode

    /// All pane IDs in this tab's pane tree.
    var allPaneIDs: [UUID] { paneTree.allPaneIDs }

    init(title: String = "shell", initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.title = title
        self.paneTree = .leaf(TerminalPane(initialWorkingDirectory: initialWorkingDirectory))
    }
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
        }
    }
}
