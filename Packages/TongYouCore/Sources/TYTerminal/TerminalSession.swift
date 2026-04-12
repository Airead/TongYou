import Foundation

/// A terminal session containing a group of tabs.
/// Sessions are displayed in the sidebar and each has independent tabs, panes, and floating panes.
public struct TerminalSession: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var tabs: [TerminalTab] = []
    public var activeTabIndex: Int = 0

    /// The currently active tab, if any.
    public var activeTab: TerminalTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    /// Number of tabs in this session.
    public var tabCount: Int { tabs.count }

    /// All pane IDs across all tabs in this session (tree + floating).
    public var allPaneIDs: [UUID] {
        tabs.flatMap(\.allPaneIDsIncludingFloating)
    }

    public init(name: String = "Session", initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.name = name
        let tab = TerminalTab(initialWorkingDirectory: initialWorkingDirectory)
        self.tabs = [tab]
    }
}
