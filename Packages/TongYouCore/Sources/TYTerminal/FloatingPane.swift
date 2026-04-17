import CoreGraphics
import Foundation

/// A floating terminal pane that can be dragged and resized within a tab.
///
/// The `frame` uses normalized coordinates (0–1) relative to the container,
/// so floating panes scale proportionally when the window resizes.
public struct FloatingPane: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pane: TerminalPane
    /// Normalized frame (0–1) relative to the container size.
    public var frame: CGRect
    public var isVisible: Bool
    public var zIndex: Int
    /// Whether this pane stays visible even when focus moves to a tree pane.
    public var isPinned: Bool
    /// Title reported by the terminal program (via OSC 0/2).
    public var title: String

    /// Default size for a new floating pane (40% width, 40% height, centered).
    public static let defaultFrame = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

    /// Minimum normalized size to prevent tiny panes.
    public static let minSize = CGSize(width: 0.1, height: 0.1)

    public init(
        pane: TerminalPane,
        frame: CGRect = FloatingPane.defaultFrame,
        isVisible: Bool = true,
        zIndex: Int = 0,
        isPinned: Bool = false,
        title: String = "Float"
    ) {
        self.id = UUID()
        self.pane = pane
        self.frame = Self.clamped(frame)
        self.isVisible = isVisible
        self.zIndex = zIndex
        self.isPinned = isPinned
        self.title = title
    }

    /// Clamp the frame so it stays within the container bounds (0–1)
    /// and respects the minimum size.
    public mutating func clampFrame() {
        frame = Self.clamped(frame)
    }

    /// Return a clamped copy of a normalized frame (0–1 bounds, minimum size enforced).
    public static func clamped(_ frame: CGRect) -> CGRect {
        let w = max(frame.width, minSize.width)
        let h = max(frame.height, minSize.height)
        let x = min(max(frame.origin.x, 0), 1 - w)
        let y = min(max(frame.origin.y, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Convert the normalized frame to pixel coordinates for a given container size.
    public func pixelFrame(in containerSize: CGSize) -> CGRect {
        Self.pixelFrame(for: frame, in: containerSize)
    }

    /// Convert an arbitrary normalized frame to pixel coordinates.
    public static func pixelFrame(for frame: CGRect, in containerSize: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x * containerSize.width,
            y: frame.origin.y * containerSize.height,
            width: frame.width * containerSize.width,
            height: frame.height * containerSize.height
        )
    }
}

extension [FloatingPane] {
    /// The z-index for the next floating pane (one above the current highest).
    public var nextZIndex: Int {
        (self.max(by: { $0.zIndex < $1.zIndex })?.zIndex ?? -1) + 1
    }

    /// Compute a cascaded frame for a new floating pane, offset to avoid
    /// stacking directly on top of existing panes.
    public func nextCascadedFrame() -> CGRect {
        let base = FloatingPane.defaultFrame
        let step: CGFloat = 0.03

        guard !isEmpty else { return base }

        var candidate = base
        for i in 0..<count {
            let offset = step * CGFloat(i + 1)
            candidate = CGRect(
                x: base.origin.x + offset,
                y: base.origin.y + offset,
                width: base.width,
                height: base.height
            )
            let collision = contains { pane in
                abs(pane.frame.origin.x - candidate.origin.x) < step / 2
                    && abs(pane.frame.origin.y - candidate.origin.y) < step / 2
            }
            if !collision { break }
        }
        return candidate
    }
}
