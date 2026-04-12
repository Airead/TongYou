import CoreGraphics
import Foundation

/// A floating terminal pane that can be dragged and resized within a tab.
///
/// The `frame` uses normalized coordinates (0–1) relative to the container,
/// so floating panes scale proportionally when the window resizes.
struct FloatingPane: Identifiable, Equatable {
    let id: UUID
    let pane: TerminalPane
    /// Normalized frame (0–1) relative to the container size.
    var frame: CGRect
    var isVisible: Bool
    var zIndex: Int
    /// Whether this pane stays visible even when focus moves to a tree pane.
    var isPinned: Bool
    /// Title reported by the terminal program (via OSC 0/2).
    var title: String

    /// Default size for a new floating pane (40% width, 40% height, centered).
    static let defaultFrame = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

    /// Minimum normalized size to prevent tiny panes.
    static let minSize = CGSize(width: 0.1, height: 0.1)

    init(
        pane: TerminalPane,
        frame: CGRect = FloatingPane.defaultFrame,
        isVisible: Bool = true,
        zIndex: Int = 0,
        isPinned: Bool = false,
        title: String = "Float"
    ) {
        self.id = UUID()
        self.pane = pane
        self.frame = frame
        self.isVisible = isVisible
        self.zIndex = zIndex
        self.isPinned = isPinned
        self.title = title
    }

    /// Clamp the frame so it stays within the container bounds (0–1)
    /// and respects the minimum size.
    mutating func clampFrame() {
        let w = max(frame.width, Self.minSize.width)
        let h = max(frame.height, Self.minSize.height)
        let x = min(max(frame.origin.x, 0), 1 - w)
        let y = min(max(frame.origin.y, 0), 1 - h)
        frame = CGRect(x: x, y: y, width: w, height: h)
    }

    /// Convert the normalized frame to pixel coordinates for a given container size.
    func pixelFrame(in containerSize: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x * containerSize.width,
            y: frame.origin.y * containerSize.height,
            width: frame.width * containerSize.width,
            height: frame.height * containerSize.height
        )
    }
}
