import Foundation

/// Output of a solver: a rect per child plus a flag indicating whether any
/// child violated `minSize`. The caller (future `LayoutEngine`) decides whether
/// a violation should be reported as a failure (e.g. block a drag) or tolerated
/// (e.g. clipped while the window is being shrunk).
public struct SolveResult: Equatable, Sendable {
    public let rects: [Rect]
    public let violated: Bool

    public init(rects: [Rect], violated: Bool) {
        self.rects = rects
        self.violated = violated
    }
}

/// Pure-function contract every layout strategy implements. Given a parent rect
/// and the (relative) weights of each child, return one rect per child.
///
/// P1 note: the signature takes `childCount: Int` rather than the `[PaneNode]`
/// mentioned in the plan §3.1 — P1 is self-contained and must not depend on the
/// new N-ary `PaneNode` (introduced in P2). Solvers only need the child count;
/// `LayoutDispatch` will forward `container.children.count` once P2 lands.
///
/// `dividerSize` is a reserved parameter: TongYou currently draws dividers in
/// SwiftUI (a few pixels wide, no grid cells reserved), so dispatch always
/// passes 0. When divider characters are eventually used, dispatch will pass 1
/// and every solver already subtracts `(N - 1) * dividerSize` from the usable
/// axis length.
public protocol LayoutSolver {
    static func solve(
        parentRect: Rect,
        childCount: Int,
        weights: [CGFloat],
        minSize: Size,
        dividerSize: Int
    ) -> SolveResult
}

// MARK: - Shared helpers

enum SolverSupport {
    /// Distribute `total` cells among `n` slots using the §3.3 remainder rule:
    /// floor each share, then hand the leftover cells out one-by-one, giving
    /// preference to the highest weights (ties broken by lower index — the
    /// leftmost / topmost child wins).
    ///
    /// Returns exactly `n` values whose sum is `total`, regardless of weights.
    static func distribute(total: Int, weights: [CGFloat]) -> [Int] {
        precondition(weights.count > 0)
        let n = weights.count
        if total <= 0 {
            return Array(repeating: 0, count: n)
        }
        let sum = weights.reduce(0, +)
        guard sum > 0 else {
            // All weights zero: split evenly.
            return distribute(total: total, weights: Array(repeating: 1, count: n))
        }
        var base = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let share = CGFloat(total) * weights[i] / sum
            base[i] = Int(share.rounded(.down))
        }
        var remainder = total - base.reduce(0, +)
        if remainder <= 0 { return base }

        // Order indices by (weight desc, index asc) for stable tie-breaking.
        let order = (0..<n).sorted { a, b in
            if weights[a] != weights[b] { return weights[a] > weights[b] }
            return a < b
        }
        var cursor = 0
        while remainder > 0 {
            base[order[cursor % n]] += 1
            cursor += 1
            remainder -= 1
        }
        return base
    }

    /// Even distribution of `total` into `n` slots (used by Grid where weights
    /// are ignored). Ties in remainder always favor lower indices.
    static func distributeEvenly(total: Int, count n: Int) -> [Int] {
        return distribute(total: total, weights: Array(repeating: 1, count: n))
    }
}
