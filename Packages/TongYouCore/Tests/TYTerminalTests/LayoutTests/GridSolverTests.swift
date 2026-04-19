import Testing
@testable import TYTerminal

@Suite("GridSolver tests", .serialized)
struct GridSolverTests {

    @Test func singleChildFillsParent() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 50)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 1,
            weights: [1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects == [parent])
        #expect(result.violated == false)
    }

    @Test func fourChildrenSquareParentIsTwoByTwo() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 100)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: Array(repeating: 1.0, count: 4),
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects == [
            Rect(x: 0,  y: 0,  width: 50, height: 50),
            Rect(x: 50, y: 0,  width: 50, height: 50),
            Rect(x: 0,  y: 50, width: 50, height: 50),
            Rect(x: 50, y: 50, width: 50, height: 50),
        ])
    }

    @Test func fourChildrenWideParentPrefersMatchingAspect() {
        // Parent aspect 4:1. With 4 panes, 2×2 gives pane aspect 60/15 = 4,
        // matching parent exactly — better than 1×4 (pane aspect 1) or 4×1.
        let parent = Rect(x: 0, y: 0, width: 120, height: 30)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: Array(repeating: 1.0, count: 4),
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.map(\.width) == [60, 60, 60, 60])
        #expect(result.rects.map(\.height) == [15, 15, 15, 15])
    }

    @Test func sixChildrenWideParentChoosesAspectMatchingGrid() {
        // W=120, H=30 (aspect 4). 2×3 gives pane aspect 40/15=2.67, 3×2 gives
        // 60/10=6. Both are equidistant from 4 in log space; floating-point
        // rounding picks 3×2 (rows=3, cols=2).
        let parent = Rect(x: 0, y: 0, width: 120, height: 30)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 6,
            weights: Array(repeating: 1.0, count: 6),
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects.count == 6)
        for r in result.rects {
            #expect(r.width == 60)
            #expect(r.height == 10)
        }
        // Row-major fill: rows at y=0, 10, 20.
        #expect(result.rects.map(\.y) == [0, 0, 10, 10, 20, 20])
    }

    @Test func weightsIgnored() {
        // Same result regardless of weights.
        let parent = Rect(x: 0, y: 0, width: 100, height: 100)
        let uniform = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        let asymmetric = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 9, 1, 9],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(uniform.rects == asymmetric.rects)
    }

    @Test func lastRowStretchesToFillWidth() {
        // 5 panes in 120×30: algorithm picks 3 rows × 2 cols. Row 0 and 1 are
        // full (2 panes at 60 each). Row 2 has 1 pane which re-divides the
        // full width and renders as 120 wide.
        let parent = Rect(x: 0, y: 0, width: 120, height: 30)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 5,
            weights: Array(repeating: 1.0, count: 5),
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        // Row 0 and row 1: full columns (60 each).
        #expect(result.rects[0] == Rect(x: 0,  y: 0,  width: 60, height: 10))
        #expect(result.rects[1] == Rect(x: 60, y: 0,  width: 60, height: 10))
        #expect(result.rects[2] == Rect(x: 0,  y: 10, width: 60, height: 10))
        #expect(result.rects[3] == Rect(x: 60, y: 10, width: 60, height: 10))
        // Row 2: 1 pane filling the full width (120).
        #expect(result.rects[4] == Rect(x: 0,  y: 20, width: 120, height: 10))
    }

    @Test func tallParentPicksAspectMatchingGrid() {
        // Parent 30×120 (aspect 0.25). 2×2 gives pane 15×60 (aspect 0.25,
        // matches parent exactly) — better than 3×1 (aspect 0.75) or 1×3.
        // With only 3 panes the last row has 1 pane that re-spans the width.
        let parent = Rect(x: 0, y: 0, width: 30, height: 120)
        let result = GridSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[0] == Rect(x: 0,  y: 0,  width: 15, height: 60))
        #expect(result.rects[1] == Rect(x: 15, y: 0,  width: 15, height: 60))
        // Last row, 1 pane: re-divides width into 30 cells.
        #expect(result.rects[2] == Rect(x: 0,  y: 60, width: 30, height: 60))
    }

    @Test func dividerReservesRowAndColumnCells() {
        // 4 panes in 100×100 with dividerSize=1 → rows usable 99, cols usable 99.
        let result = GridSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 100, height: 100),
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(result.rects == [
            Rect(x: 0,  y: 0,  width: 50, height: 50),
            Rect(x: 51, y: 0,  width: 49, height: 50),
            Rect(x: 0,  y: 51, width: 50, height: 49),
            Rect(x: 51, y: 51, width: 49, height: 49),
        ])
    }

    @Test func dividerZeroVsOneDiffersOnTotals() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 100)
        let d0 = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        let d1 = GridSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(d0 != d1)
        // With dividerSize=0, row widths tile exactly: col0(50) + col1(50) = 100.
        #expect(d0.rects[0].width + d0.rects[1].width == 100)
        // With dividerSize=1, row widths + 1 divider cell = 100.
        #expect(d1.rects[0].width + d1.rects[1].width + 1 == 100)
    }

    @Test func minSizeViolationBubbles() {
        // 9 panes in a 30×30 parent → 3×3 grid with each pane 10×10; minWidth
        // default 20 → violation.
        let result = GridSolver.solve(
            parentRect: Rect(x: 0, y: 0, width: 30, height: 30),
            childCount: 9,
            weights: Array(repeating: 1.0, count: 9),
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == true)
    }

    @Test func originOffsetPreserved() {
        let result = GridSolver.solve(
            parentRect: Rect(x: 10, y: 20, width: 100, height: 100),
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[0].x == 10)
        #expect(result.rects[0].y == 20)
        #expect(result.rects[3].x == 60)
        #expect(result.rects[3].y == 70)
    }
}
