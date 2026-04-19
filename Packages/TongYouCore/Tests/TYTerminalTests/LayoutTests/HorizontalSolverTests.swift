import Testing
@testable import TYTerminal

@Suite("HorizontalSolver tests", .serialized)
struct HorizontalSolverTests {

    private let parent = Rect(x: 0, y: 0, width: 120, height: 30)

    @Test func singleChildFillsParent() {
        let result = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 1,
            weights: [1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(result.rects == [parent])
        #expect(result.violated == false)
    }

    @Test func uniformWeightsSplitEvenly() {
        let result = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        // 30 / 3 = 10 each, no remainder
        #expect(result.rects.map(\.height) == [10, 10, 10])
        #expect(result.rects.map(\.y) == [0, 10, 20])
        // Width always matches parent width.
        for r in result.rects { #expect(r.width == 120); #expect(r.x == 0) }
        #expect(result.violated == false)
    }

    @Test func asymmetricWeights() {
        let result = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 2],
            minSize: .defaultMin,
            dividerSize: 0
        )
        // Expected ratios: 7.5 / 7.5 / 15 → floored 7/7/15, remainder 1 → goes
        // to weight=2 child (index 2), so heights = 7/7/16? Let's trace:
        // total=30, weights=[1,1,2], sum=4
        // shares = 7.5, 7.5, 15.0 → floor 7, 7, 15 → base sum = 29, remainder 1
        // Order by weight desc: [2, 0, 1], so child 2 gets +1 → [7, 7, 16]
        #expect(result.rects.map(\.height) == [7, 7, 16])
        #expect(result.rects.map(\.y) == [0, 7, 14])
    }

    @Test func remainderPrefersHighestWeightThenLowestIndex() {
        // Total 10, weights [1, 1, 1] → base floor 3/3/3, remainder 1 → index 0.
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 10),
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.height) == [4, 3, 3])
    }

    @Test func remainderMultipleCellsSpreadInOrder() {
        // Total 11, weights [1, 1, 1] → base 3/3/3, remainder 2 → indices 0, 1.
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 11),
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.height) == [4, 4, 3])
    }

    @Test func extremeWeightRatio() {
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 100),
            childCount: 2,
            weights: [99, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.height) == [99, 1])
    }

    @Test func dividerSizeSubtractsFromUsableAxis() {
        // height=30, 3 children, dividerSize=1 → usable=28, evenly 10/9/9 with
        // remainder 1 going to index 0.
        let result = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(result.rects.map(\.height) == [10, 9, 9])
        // Y cursor advances by height + divider between siblings.
        #expect(result.rects.map(\.y) == [0, 11, 21])
    }

    @Test func dividerSizeZeroMatchesTightPacking() {
        let withoutDivider = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        let totalHeight = withoutDivider.rects.map(\.height).reduce(0, +)
        #expect(totalHeight == parent.height)
    }

    @Test func minSizeViolationOnWindowShrink() {
        // minHeight=3 but child gets 1 cell → violated=true, rect still 1.
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 120, height: 2),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == true)
        #expect(result.rects.map(\.height) == [1, 1])
    }

    @Test func minSizeRespectedWhenParentLargeEnough() {
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 120, height: 30),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == false)
    }

    @Test func widthViolationPropagates() {
        // Parent too narrow: every child inherits width, all violate.
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 10, height: 30),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == true)
        for r in result.rects { #expect(r.width == 10) }
    }

    @Test func originOffsetPreserved() {
        let result = HorizontalSolver.solve(
            parentRect: Rect(x: 5, y: 7, width: 100, height: 20),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.x) == [5, 5])
        #expect(result.rects.map(\.y) == [7, 17])
    }
}
