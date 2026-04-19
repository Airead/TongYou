import Foundation

/// Master-stack container (plan §3.5). Flat layout:
///
///     children = [master, stack_0, stack_1, …]
///     weights  = [masterWeight, s_0, s_1, …]
///
/// - `weights[0] / sum(weights)` determines the master column width (horizontal
///   split between master on the left and the stack region on the right).
/// - `weights[1...]` divide the stack region's height between the stack panes
///   using the same §3.3 remainder rule as Horizontal.
///
/// With only the master present (N = 1) the master fills the whole parent.
public enum MasterStackSolver: LayoutSolver {
    public static func solve(
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size,
        dividerSize: Int
    ) -> SolveResult {
        precondition(childCount == weights.count, "childCount must match weights.count")
        precondition(childCount >= 1, "Container must have at least one child")
        precondition(dividerSize >= 0, "dividerSize must be non-negative")

        let n = childCount

        // Degenerate case: only the master exists, fills everything.
        if n == 1 {
            let rect = parentRect
            let violated = rect.width < minSize.width || rect.height < minSize.height
            return SolveResult(rects: [rect], violated: violated)
        }

        // Horizontal split: master | stack.
        let horizontalUsable = max(0, parentRect.width - dividerSize)
        let masterWeight = weights[0]
        let stackWeights = Array(weights[1...])
        let stackSum = stackWeights.reduce(0, +)
        let topWeights: [CGFloat] = [masterWeight, stackSum]
        let columnWidths = SolverSupport.distribute(total: horizontalUsable, weights: topWeights)
        let masterWidth = columnWidths[0]
        let stackWidth = columnWidths[1]
        let masterRect = Rect(
            x: parentRect.x,
            y: parentRect.y,
            width: masterWidth,
            height: parentRect.height
        )
        let stackOriginX = parentRect.x + masterWidth + dividerSize

        // Vertical subdivision of the stack column.
        let stackCount = n - 1
        let stackHeightUsable = max(0, parentRect.height - (stackCount - 1) * dividerSize)
        let stackHeights = SolverSupport.distribute(total: stackHeightUsable, weights: stackWeights)

        var rects: [Rect] = [masterRect]
        rects.reserveCapacity(n)
        var violated = masterRect.width < minSize.width || masterRect.height < minSize.height
        var cursorY = parentRect.y
        for i in 0..<stackCount {
            let h = stackHeights[i]
            let rect = Rect(
                x: stackOriginX,
                y: cursorY,
                width: stackWidth,
                height: h
            )
            rects.append(rect)
            if rect.width < minSize.width || rect.height < minSize.height {
                violated = true
            }
            cursorY += h + dividerSize
        }
        return SolveResult(rects: rects, violated: violated)
    }
}
