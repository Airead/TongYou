import Testing
@testable import TYTerminal

@Suite("VerticalSolver tests", .serialized)
struct VerticalSolverTests {

    private let parent = Rect(x: 0, y: 0, width: 120, height: 30)

    @Test func singleChildFillsParent() {
        let result = VerticalSolver.solve(
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
        let result = VerticalSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [30, 30, 30, 30])
        #expect(result.rects.map(\.x) == [0, 30, 60, 90])
        for r in result.rects {
            #expect(r.height == 30)
            #expect(r.y == 0)
        }
    }

    @Test func asymmetricWeights() {
        // 120 cells, weights [1,1,2], sum=4 → floor 30/30/60 exactly.
        let result = VerticalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 2],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [30, 30, 60])
        #expect(result.rects.map(\.x) == [0, 30, 60])
    }

    @Test func remainderDescendingWeights() {
        // total=10, weights=[3, 2, 1], sum=6
        // shares = 5.0, 3.33, 1.67 → floor 5, 3, 1 → base=9, remainder=1
        // weight order desc: [0, 1, 2] → child 0 +1 → [6, 3, 1]
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 10, height: 100),
            childCount: 3,
            weights: [3, 2, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [6, 3, 1])
    }

    @Test func remainderEqualWeightsFavorLowerIndex() {
        // total=7, weights=[1,1,1,1] → base 1/1/1/1 sum=4, remainder=3 → idx 0,1,2
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 7, height: 10),
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [2, 2, 2, 1])
    }

    @Test func extremeWeightRatio() {
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 30),
            childCount: 2,
            weights: [99, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [99, 1])
    }

    @Test func dividerSizeOneReservesCellsBetween() {
        // width=120, 3 children, dividerSize=1 → usable=118, evenly 40/39/39
        let result = VerticalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(result.rects.map(\.width) == [40, 39, 39])
        #expect(result.rects.map(\.x) == [0, 41, 81])
    }

    @Test func dividerZeroVersusOneDiffers() {
        let d0 = VerticalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        let d1 = VerticalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(d0.rects.map(\.width).reduce(0, +) == parent.width)
        #expect(d1.rects.map(\.width).reduce(0, +) == parent.width - 2)
    }

    @Test func minSizeViolationOnSqueeze() {
        // minWidth=20 but parent width 30 split between 2 → each gets 15.
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 30, height: 30),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == true)
        #expect(result.rects.map(\.width) == [15, 15])
    }

    @Test func minSizeHonoredWhenParentSufficient() {
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 30),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == false)
    }

    @Test func originOffsetPreserved() {
        let result = VerticalSolver.solve(
            parentRect: Rect(x: 5, y: 7, width: 40, height: 10),
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.x) == [5, 25])
        for r in result.rects { #expect(r.y == 7); #expect(r.height == 10) }
    }
}
