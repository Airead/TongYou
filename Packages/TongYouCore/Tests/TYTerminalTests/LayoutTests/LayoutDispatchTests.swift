import Testing
@testable import TYTerminal

@Suite("LayoutDispatch tests", .serialized)
struct LayoutDispatchTests {

    private let parent = Rect(x: 0, y: 0, width: 100, height: 40)

    @Test func horizontalKindRoutesToHorizontalSolver() {
        let dispatched = LayoutDispatch.solve(
            kind: .horizontal,
            parentRect: parent,
            childCount: 2,
            weights: [1, 1]
        )
        let direct = HorizontalSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(dispatched == direct)
    }

    @Test func verticalKindRoutesToVerticalSolver() {
        let dispatched = LayoutDispatch.solve(
            kind: .vertical,
            parentRect: parent,
            childCount: 3,
            weights: [1, 2, 1]
        )
        let direct = VerticalSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 2, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(dispatched == direct)
    }

    @Test func gridKindRoutesToGridSolver() {
        let dispatched = LayoutDispatch.solve(
            kind: .grid,
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1]
        )
        let direct = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(dispatched == direct)
    }

    @Test func masterStackKindRoutesToMasterStackSolver() {
        let dispatched = LayoutDispatch.solve(
            kind: .masterStack,
            parentRect: parent,
            childCount: 3,
            weights: [3, 1, 1]
        )
        let direct = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [3, 1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(dispatched == direct)
    }

    @Test func fibonacciKindFallsBackToGridSolver() {
        // Fibonacci is reserved for P4+. Dispatch falls back to grid to keep
        // early integrators visually sane.
        let dispatched = LayoutDispatch.solve(
            kind: .fibonacci,
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1]
        )
        let gridDirect = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: .defaultMin,
            dividerSize: 0
        )
        #expect(dispatched == gridDirect)
    }

    @Test func defaultMinSizeIsTwentyByThree() {
        // A 2-child horizontal split of a 30-tall parent gives 15 each, below
        // minHeight=3… no wait, 15 > 3. Use a parent where height is 4 to
        // trigger violation (2 each < 3).
        let result = LayoutDispatch.solve(
            kind: .horizontal,
            parentRect: Rect(x: 0, y: 0, width: 100, height: 4),
            childCount: 2,
            weights: [1, 1]
        )
        #expect(result.violated == true)
    }

    @Test func defaultDividerSizeIsZero() {
        let result = LayoutDispatch.solve(
            kind: .vertical,
            parentRect: parent,
            childCount: 2,
            weights: [1, 1]
        )
        // Cells tile exactly: widths sum to parent width.
        #expect(result.rects.map(\.width).reduce(0, +) == parent.width)
    }

    @Test func dividerSizeForwardsToSolver() {
        let withDivider = LayoutDispatch.solve(
            kind: .vertical,
            parentRect: parent,
            childCount: 2,
            weights: [1, 1],
            dividerSize: 1
        )
        // Widths sum to parent.width - 1 when a divider is reserved.
        #expect(withDivider.rects.map(\.width).reduce(0, +) == parent.width - 1)
    }

    @Test func coversEveryStrategyKind() {
        // Guard against forgetting to route a new case in LayoutDispatch.
        for kind in LayoutStrategyKind.allCases {
            let result = LayoutDispatch.solve(
                kind: kind,
                parentRect: parent,
                childCount: 2,
                weights: [1, 1]
            )
            #expect(result.rects.count == 2, "kind \(kind) should return one rect per child")
        }
    }
}
