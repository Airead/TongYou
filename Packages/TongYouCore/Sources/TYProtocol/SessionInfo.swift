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
    public var floatingPanes: [FloatingPaneInfo]
    /// The pane that was last focused in this tab. Nil if unknown.
    public var focusedPaneID: PaneID?

    public init(id: TabID, title: String, layout: LayoutTree, floatingPanes: [FloatingPaneInfo] = [], focusedPaneID: PaneID? = nil) {
        self.id = id
        self.title = title
        self.layout = layout
        self.floatingPanes = floatingPanes
        self.focusedPaneID = focusedPaneID
    }
}

/// Serializable representation of a floating pane's state.
public struct FloatingPaneInfo: Equatable, Sendable {
    public let paneID: PaneID
    /// Normalized frame (0–1) relative to the container size.
    public var frameX: Float
    public var frameY: Float
    public var frameWidth: Float
    public var frameHeight: Float
    public var zIndex: Int32
    public var isPinned: Bool
    public var isVisible: Bool
    public var title: String

    public init(
        paneID: PaneID,
        frameX: Float = 0.3, frameY: Float = 0.3,
        frameWidth: Float = 0.4, frameHeight: Float = 0.4,
        zIndex: Int32 = 0,
        isPinned: Bool = false,
        isVisible: Bool = true,
        title: String = "Float"
    ) {
        self.paneID = paneID
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.zIndex = zIndex
        self.isPinned = isPinned
        self.isVisible = isVisible
        self.title = title
    }
}

/// Serializable representation of the pane layout tree.
/// Mirrors `PaneNode` from TYTerminal but uses protocol-layer IDs.
public indirect enum LayoutTree: Sendable, Equatable {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: Float, first: LayoutTree, second: LayoutTree)
}
