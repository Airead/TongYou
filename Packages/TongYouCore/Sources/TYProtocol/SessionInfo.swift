import Foundation
import TYTerminal

/// Information about a session, suitable for listing and display.
public struct SessionInfo: Equatable, Sendable {
    public let id: SessionID
    public var name: String
    public var tabs: [TabInfo]
    public var activeTabIndex: Int

    public init(id: SessionID, name: String, tabs: [TabInfo] = [], activeTabIndex: Int = 0) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
    }
}

/// Information about a tab within a session.
public struct TabInfo: Equatable, Sendable {
    public let id: TabID
    public var title: String
    public var layout: LayoutTree

    public init(id: TabID, title: String, layout: LayoutTree) {
        self.id = id
        self.title = title
        self.layout = layout
    }
}

/// Serializable representation of the pane layout tree.
/// Mirrors `PaneNode` from TYTerminal but uses protocol-layer IDs.
public indirect enum LayoutTree: Sendable, Equatable {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: Float, first: LayoutTree, second: LayoutTree)
}
