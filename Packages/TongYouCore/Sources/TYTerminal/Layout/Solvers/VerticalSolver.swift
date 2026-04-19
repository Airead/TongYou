import Foundation

/// Vertical container: children sit **side by side** (left/right columns), each
/// spanning the parent's full height. The primary axis divided by weights is
/// the parent's width.
public enum VerticalSolver: LayoutSolver {
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
        let usable = max(0, parentRect.width - (n - 1) * dividerSize)
        let widths = SolverSupport.distribute(total: usable, weights: weights)

        var rects: [Rect] = []
        rects.reserveCapacity(n)
        var violated = false
        var cursorX = parentRect.x
        for i in 0..<n {
            let w = widths[i]
            let rect = Rect(
                x: cursorX,
                y: parentRect.y,
                width: w,
                height: parentRect.height
            )
            rects.append(rect)
            if w < minSize.width || parentRect.height < minSize.height {
                violated = true
            }
            cursorX += w + dividerSize
        }
        return SolveResult(rects: rects, violated: violated)
    }
}
