import Foundation

/// Horizontal container: children stack **vertically** (top/bottom rows), each
/// spanning the parent's full width. The primary axis divided by weights is
/// therefore the parent's height.
public enum HorizontalSolver: LayoutSolver {
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
        let usable = max(0, parentRect.height - (n - 1) * dividerSize)
        let heights = SolverSupport.distribute(total: usable, weights: weights)

        var rects: [Rect] = []
        rects.reserveCapacity(n)
        var violated = false
        var cursorY = parentRect.y
        for i in 0..<n {
            let h = heights[i]
            let rect = Rect(
                x: parentRect.x,
                y: cursorY,
                width: parentRect.width,
                height: h
            )
            rects.append(rect)
            if h < minSize.height || parentRect.width < minSize.width {
                violated = true
            }
            cursorY += h + dividerSize
        }
        return SolveResult(rects: rects, violated: violated)
    }
}
