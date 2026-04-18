import CoreGraphics
import Foundation

/// A single terminal tab containing a tree of panes.
public struct TerminalTab: Identifiable, Sendable {
    public static let defaultTitle = "shell"

    public let id: UUID
    public var title: String
    public var paneTree: PaneNode
    public var floatingPanes: [FloatingPane] = []
    /// The pane that was last focused in this tab. Used to restore focus when switching back.
    public var focusedPaneID: UUID?

    /// All pane IDs in this tab's pane tree (does not include floating panes).
    public var allPaneIDs: [UUID] { paneTree.allPaneIDs }

    /// All pane IDs including both tree panes and floating panes.
    public var allPaneIDsIncludingFloating: [UUID] {
        paneTree.allPaneIDs + floatingPanes.map(\.pane.id)
    }

    /// Whether this tab contains a pane with the given ID.
    public func hasPane(id: UUID) -> Bool {
        paneTree.contains(paneID: id) || floatingPanes.contains(where: { $0.pane.id == id })
    }

    public init(title: String = "shell", initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.title = title
        self.paneTree = .leaf(TerminalPane(initialWorkingDirectory: initialWorkingDirectory))
    }

    /// Build a tab whose root pane is supplied by the caller. Used when the
    /// caller (e.g. `SessionManager.createPane`) has already resolved a
    /// profile and constructed a `TerminalPane` with its `startupSnapshot`.
    public init(title: String = "shell", initialPane: TerminalPane) {
        self.id = UUID()
        self.title = title
        self.paneTree = .leaf(initialPane)
    }

    public init(id: UUID, title: String, paneTree: PaneNode, floatingPanes: [FloatingPane] = [], focusedPaneID: UUID? = nil) {
        self.id = id
        self.title = title
        self.paneTree = paneTree
        self.floatingPanes = floatingPanes
        self.focusedPaneID = focusedPaneID
    }
}
