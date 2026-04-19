import Foundation

/// Central `kind → solver` dispatch. Layers above the solver (P3's
/// `LayoutEngine`, the renderer) call into this instead of touching individual
/// solver types.
///
/// P1 note: the signature accepts `childCount: Int` rather than a `Container`.
/// When P2 introduces the N-ary `Container` type, a convenience overload taking
/// `Container` can forward `container.children.count` here unchanged.
public enum LayoutDispatch {
    public static func solve(
        kind: LayoutStrategyKind,
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size = .defaultMin,
        dividerSize: Int = 0
    ) -> SolveResult {
        switch kind {
        case .horizontal:
            return HorizontalSolver.solve(
                parentRect: parentRect,
                childCount: childCount,
                weights: weights,
                minSize: minSize,
                dividerSize: dividerSize
            )
        case .vertical:
            return VerticalSolver.solve(
                parentRect: parentRect,
                childCount: childCount,
                weights: weights,
                minSize: minSize,
                dividerSize: dividerSize
            )
        case .grid:
            return GridSolver.solve(
                parentRect: parentRect,
                childCount: childCount,
                weights: weights,
                minSize: minSize,
                dividerSize: dividerSize
            )
        case .masterStack:
            return MasterStackSolver.solve(
                parentRect: parentRect,
                childCount: childCount,
                weights: weights,
                minSize: minSize,
                dividerSize: dividerSize
            )
        case .fibonacci:
            // Reserved for P4+. Falling back to grid keeps early integrators
            // visually sane if they flip the strategy before the solver lands.
            return GridSolver.solve(
                parentRect: parentRect,
                childCount: childCount,
                weights: weights,
                minSize: minSize,
                dividerSize: dividerSize
            )
        }
    }
}
