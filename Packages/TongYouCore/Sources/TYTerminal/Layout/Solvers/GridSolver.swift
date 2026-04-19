import Foundation

/// Grid container: arrange N children in an R×C grid. Algorithm (plan §3.5):
///
/// 1. If `gridRowWeights` and `gridColWeights` are non-empty and
///    `gridRowWeights.count × gridColWeights.count == N`, use them to pin the
///    grid's shape and per-row / per-column sizes — this is the
///    user-customized path enabled by dragging dividers.
/// 2. Otherwise auto-balance: pick (R, C) by enumerating R ∈ [1, N],
///    C = ⌈N / R⌉, and choose the combination whose per-pane aspect ratio
///    `(W/C) / (H/R)` is closest to the parent rect's aspect ratio `W/H`.
/// 3. Fill row-major: child `i` goes to row `i/C`, column `i%C`.
/// 4. In auto mode, if the last row has `k < C` panes, that row re-divides
///    the full width across `k` slots; earlier rows keep their `W/C` column
///    width. Custom-weight mode requires `N = R·C` (no partial last row).
public enum GridSolver: LayoutSolver {
    public static func solve(
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size,
        dividerSize: Int
    ) -> SolveResult {
        solve(
            parentRect: parentRect,
            childCount: childCount,
            weights: weights,
            minSize: minSize,
            dividerSize: dividerSize,
            gridRowWeights: [],
            gridColWeights: []
        )
    }

    /// Grid-specific solve that can honor custom per-row / per-column weights.
    /// Pass empty arrays for auto-balanced behavior (equivalent to the
    /// protocol-conforming overload above).
    public static func solve(
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size,
        dividerSize: Int,
        gridRowWeights: [CGFloat],
        gridColWeights: [CGFloat]
    ) -> SolveResult {
        precondition(childCount == weights.count, "childCount must match weights.count")
        precondition(childCount >= 1, "Container must have at least one child")
        precondition(dividerSize >= 0, "dividerSize must be non-negative")

        let n = childCount
        let useCustom = !gridRowWeights.isEmpty
            && !gridColWeights.isEmpty
            && gridRowWeights.count * gridColWeights.count == n
        let rows: Int
        let cols: Int
        if useCustom {
            rows = gridRowWeights.count
            cols = gridColWeights.count
        } else {
            (rows, cols) = chooseRowsCols(n: n, parent: parentRect)
        }

        // Row heights: custom weights divide proportionally; auto uses even.
        let usableHeight = max(0, parentRect.height - (rows - 1) * dividerSize)
        let rowHeights: [Int] = useCustom
            ? SolverSupport.distribute(total: usableHeight, weights: gridRowWeights)
            : SolverSupport.distributeEvenly(total: usableHeight, count: rows)

        // Per-row column widths: full rows use `cols` columns (custom weights
        // when available), last row may be shorter in auto mode and
        // re-divides the same horizontal space evenly across its `k` slots.
        let fullRowWidths: [Int] = {
            let usableW = max(0, parentRect.width - (cols - 1) * dividerSize)
            return useCustom
                ? SolverSupport.distribute(total: usableW, weights: gridColWeights)
                : SolverSupport.distributeEvenly(total: usableW, count: cols)
        }()
        let lastRowCount = n - (rows - 1) * cols
        let lastRowWidths: [Int] = {
            guard lastRowCount != cols else { return fullRowWidths }
            // Only reachable in auto mode (custom mode requires N = R·C).
            let usableW = max(0, parentRect.width - (lastRowCount - 1) * dividerSize)
            return SolverSupport.distributeEvenly(total: usableW, count: lastRowCount)
        }()

        var rects: [Rect] = []
        rects.reserveCapacity(n)
        var violated = false
        var cursorY = parentRect.y
        for r in 0..<rows {
            let isLast = r == rows - 1
            let rowWidths = isLast ? lastRowWidths : fullRowWidths
            let rowPanes = isLast ? lastRowCount : cols
            let h = rowHeights[r]
            var cursorX = parentRect.x
            for c in 0..<rowPanes {
                let w = rowWidths[c]
                rects.append(Rect(x: cursorX, y: cursorY, width: w, height: h))
                if w < minSize.width || h < minSize.height {
                    violated = true
                }
                cursorX += w + dividerSize
            }
            cursorY += h + dividerSize
        }
        return SolveResult(rects: rects, violated: violated)
    }

    /// Pick (rows, cols) such that per-pane aspect ratio approximates the
    /// parent's. Ties favor fewer rows (wider grids), matching the visual feel
    /// of iTerm2 / Kitty when you throw 4 panes into a wide window. Exposed
    /// so the renderer can mirror the auto-balanced R×C when the user hasn't
    /// customized the grid yet.
    public static func chooseRowsCols(n: Int, parent: Rect) -> (rows: Int, cols: Int) {
        if n == 1 { return (1, 1) }
        let parentAspect: CGFloat = {
            guard parent.height > 0 else { return 1 }
            return CGFloat(parent.width) / CGFloat(parent.height)
        }()

        var bestRows = 1
        var bestCols = n
        var bestScore = CGFloat.greatestFiniteMagnitude
        for r in 1...n {
            let c = Int((Double(n) / Double(r)).rounded(.up))
            let paneW = max(1, parent.width / max(1, c))
            let paneH = max(1, parent.height / max(1, r))
            let paneAspect = CGFloat(paneW) / CGFloat(paneH)
            // Log-ratio keeps "twice too wide" and "twice too tall" equally bad.
            let ratio = paneAspect / parentAspect
            let score = abs(log(Double(ratio)))
            if CGFloat(score) < bestScore {
                bestScore = CGFloat(score)
                bestRows = r
                bestCols = c
            }
        }
        return (bestRows, bestCols)
    }
}
