import Foundation
import TYTerminal

/// Per-pane metadata sent alongside session info from the server.
/// Add new fields here as the protocol evolves.
public struct RemotePaneMetadata: Equatable, Sendable, Codable {
    /// Current working directory of the pane's shell process.
    public var cwd: String?
    /// Profile id the pane was created with. Lets the client resolve the
    /// profile's Live fields locally for rendering (theme/palette/etc.).
    /// Optional for backwards compatibility with older servers.
    public var profileID: String?

    public init(cwd: String? = nil, profileID: String? = nil) {
        self.cwd = cwd
        self.profileID = profileID
    }
}

/// Information about a session, suitable for listing and display.
public struct SessionInfo: Equatable, Sendable, Codable {
    public let id: SessionID
    public var name: String
    public var tabs: [TabInfo]
    public var activeTabIndex: Int
    /// Extended metadata for each pane, keyed by server pane ID.
    public var paneMetadata: [PaneID: RemotePaneMetadata]

    public init(id: SessionID, name: String, tabs: [TabInfo] = [], activeTabIndex: Int = 0, paneMetadata: [PaneID: RemotePaneMetadata] = [:]) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.paneMetadata = paneMetadata
    }
}

/// Information about a tab within a session.
public struct TabInfo: Equatable, Sendable, Codable {
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
public struct FloatingPaneInfo: Equatable, Sendable, Codable {
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
public indirect enum LayoutTree: Sendable, Equatable, Codable {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: Float, first: LayoutTree, second: LayoutTree)

    private enum CodingKeys: String, CodingKey {
        case type
        case paneID
        case direction
        case ratio
        case first
        case second
    }

    private enum LayoutType: String, Codable {
        case leaf
        case split
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneID):
            try container.encode(LayoutType.leaf, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case .split(let direction, let ratio, let first, let second):
            try container.encode(LayoutType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(LayoutType.self, forKey: .type)
        switch type {
        case .leaf:
            let paneID = try container.decode(PaneID.self, forKey: .paneID)
            self = .leaf(paneID)
        case .split:
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let ratio = try container.decode(Float.self, forKey: .ratio)
            let first = try container.decode(LayoutTree.self, forKey: .first)
            let second = try container.decode(LayoutTree.self, forKey: .second)
            self = .split(direction: direction, ratio: ratio, first: first, second: second)
        }
    }
}
