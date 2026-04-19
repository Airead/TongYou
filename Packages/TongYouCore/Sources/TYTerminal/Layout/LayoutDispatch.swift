import Foundation

/// Central `kind → solver` dispatch. Layers above the solver (P3's
/// `LayoutEngine`, the renderer) call into this instead of touching individual
/// solver types.
public enum LayoutDispatch {
    /// Convenience overload that forwards a `Container`'s own strategy,
    /// child count, and weights. Introduced in P2 once the N-ary `Container`
    /// type landed in `TYTerminal`.
    public static func solve(
        container: Container,
        in parentRect: Rect,
        minSize: Size = .defaultMin,
        dividerSize: Int = 0
    ) -> SolveResult {
        solve(
            kind: container.strategy,
            parentRect: parentRect,
            childCount: container.children.count,
            weights: container.weights,
            minSize: minSize,
            dividerSize: dividerSize,
            gridRowWeights: container.gridRowWeights,
            gridColWeights: container.gridColWeights
        )
    }

    public static func solve(
        kind: LayoutStrategyKind,
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size = .defaultMin,
        dividerSize: Int = 0,
        gridRowWeights: [CGFloat] = [],
        gridColWeights: [CGFloat] = []
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
                dividerSize: dividerSize,
                gridRowWeights: gridRowWeights,
                gridColWeights: gridColWeights
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
                dividerSize: dividerSize,
                gridRowWeights: gridRowWeights,
                gridColWeights: gridColWeights
            )
        }
    }
}
