import Foundation

/// A terminal session containing a group of tabs.
/// Sessions are displayed in the sidebar and each has independent tabs, panes, and floating panes.
struct TerminalSession: Identifiable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab] = []
    var activeTabIndex: Int = 0

    /// The currently active tab, if any.
    var activeTab: TerminalTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    /// Number of tabs in this session.
    var tabCount: Int { tabs.count }

    /// All pane IDs across all tabs in this session (tree + floating).
    var allPaneIDs: [UUID] {
        tabs.flatMap(\.allPaneIDsIncludingFloating)
    }

    init(name: String = "Session", initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.name = name
        let tab = TerminalTab(initialWorkingDirectory: initialWorkingDirectory)
        self.tabs = [tab]
    }
}
