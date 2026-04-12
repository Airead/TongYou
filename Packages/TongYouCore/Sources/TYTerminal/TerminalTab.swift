import CoreGraphics
import Foundation

/// A single terminal tab containing a tree of panes.
public struct TerminalTab: Identifiable, Sendable {
    public static let defaultTitle = "shell"

    public let id: UUID
    public var title: String
    public var paneTree: PaneNode
    public var floatingPanes: [FloatingPane] = []

    /// All pane IDs in this tab's pane tree (does not include floating panes).
    public var allPaneIDs: [UUID] { paneTree.allPaneIDs }

    /// All pane IDs including both tree panes and floating panes.
    public var allPaneIDsIncludingFloating: [UUID] {
        paneTree.allPaneIDs + floatingPanes.map(\.pane.id)
    }

    public init(title: String = "shell", initialWorkingDirectory: String? = nil) {
        self.id = UUID()
        self.title = title
        self.paneTree = .leaf(TerminalPane(initialWorkingDirectory: initialWorkingDirectory))
    }
}
