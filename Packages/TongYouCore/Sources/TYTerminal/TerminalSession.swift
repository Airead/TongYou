import Foundation

/// Identifies whether a session runs locally or is backed by a remote tongyou server.
public enum SessionSource: Sendable, Equatable {
    /// Local PTY session managed directly by the GUI.
    case local
    /// Remote session managed by a tongyou server.
    /// `serverSessionID` is the UUID of the session on the server side.
    case remote(serverSessionID: UUID)

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    public var serverSessionID: UUID? {
        if case .remote(let id) = self { return id }
        return nil
    }
}

/// A terminal session containing a group of tabs.
/// Sessions are displayed in the sidebar and each has independent tabs, panes, and floating panes.
public struct TerminalSession: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var tabs: [TerminalTab] = []
    public var activeTabIndex: Int = 0

    /// Whether this session is local or backed by a remote tongyou server.
    public var source: SessionSource

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

    /// Whether this session contains a pane with the given ID.
    public func hasPane(id: UUID) -> Bool {
        tabs.contains(where: { $0.hasPane(id: id) })
    }

    public init(name: String = "Session", initialWorkingDirectory: String? = nil, source: SessionSource = .local) {
        self.id = UUID()
        self.name = name
        self.source = source
        let tab = TerminalTab(initialWorkingDirectory: initialWorkingDirectory)
        self.tabs = [tab]
    }

    /// Create a local session with a specific ID (used for restoration from persistence).
    public init(id: UUID, name: String, tabs: [TerminalTab], activeTabIndex: Int = 0, source: SessionSource = .local) {
        self.id = id
        self.name = name
        self.source = source
        self.tabs = tabs.isEmpty ? [TerminalTab()] : tabs
        self.activeTabIndex = activeTabIndex
    }

    /// Create a remote session from server-provided info.
    /// Uses the server's session UUID as the local session ID for 1:1 mapping.
    public init(remoteSessionID: UUID, name: String, tabs: [TerminalTab]) {
        self.id = remoteSessionID
        self.name = name
        self.source = .remote(serverSessionID: remoteSessionID)
        self.tabs = tabs.isEmpty ? [TerminalTab()] : tabs
    }
}
