import Foundation

/// The layout strategy applied to a single `Container` in the pane tree.
/// A new strategy is added by appending a case here and implementing a matching
/// solver that `LayoutDispatch` forwards to.
public enum LayoutStrategyKind: String, Sendable, Codable, CaseIterable {
    /// Stack children vertically (split happens along the Y axis; children
    /// share the parent's width, divide its height).
    case horizontal

    /// Place children side by side (split happens along the X axis; children
    /// share the parent's height, divide its width).
    case vertical

    /// Auto-balanced R×C grid. Weights are ignored.
    case grid

    /// One master pane on the left + stacked siblings on the right.
    case masterStack

    /// Spiral subdivision (reserved for P4+, not implemented in P1).
    case fibonacci
}
