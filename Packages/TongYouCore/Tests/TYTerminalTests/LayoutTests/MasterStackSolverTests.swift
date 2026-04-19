import Testing
@testable import TYTerminal

@Suite("MasterStackSolver tests", .serialized)
struct MasterStackSolverTests {

    @Test func singleChildActsAsMasterFillingParent() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 50)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 1,
            weights: [1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects == [parent])
        #expect(result.violated == false)
    }

    @Test func twoChildrenSplitHorizontally() {
        // weights [3, 2] → master = 60%, stack = 40% wide, stack has 1 pane
        let parent = Rect(x: 0, y: 0, width: 100, height: 80)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [3, 2],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects == [
            Rect(x: 0,  y: 0, width: 60, height: 80),   // master
            Rect(x: 60, y: 0, width: 40, height: 80),   // stack (single pane)
        ])
    }

    @Test func initialSixtyPercentMasterConvention() {
        // Plan convention: new masterStack containers initialize
        // weights[0] = sum(weights[1...]) × 1.5 → master ≈ 60%.
        // 3 stack panes with weight 1 each: masterWeight = 4.5, total = 7.5.
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [4.5, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        // Master takes 60 cells = 60% of 100.
        #expect(result.rects[0] == Rect(x: 0, y: 0, width: 60, height: 30))
        // Stack column occupies the remaining 40 cells, 3 panes 10 tall each.
        #expect(result.rects[1] == Rect(x: 60, y: 0,  width: 40, height: 10))
        #expect(result.rects[2] == Rect(x: 60, y: 10, width: 40, height: 10))
        #expect(result.rects[3] == Rect(x: 60, y: 20, width: 40, height: 10))
    }

    @Test func masterWeightCanBeChangedAfterDrag() {
        // Simulate user dragging master wider: weight 9 vs 1 → 90% master.
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [9, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[0].width == 90)
        #expect(result.rects[1].width == 10)
    }

    @Test func stackPaneWeightsDistributeHeight() {
        // Stack: weights [1, 3, 1] (sum 5) → stack panes 20%, 60%, 20%.
        let parent = Rect(x: 0, y: 0, width: 100, height: 50)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [5, 1, 3, 1],   // master weight matches stack sum → 50/50
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[0].width == 50)
        // Stack heights: distribute(50, [1, 3, 1]) = floor 10/30/10 exact.
        #expect(result.rects[1].height == 10)
        #expect(result.rects[2].height == 30)
        #expect(result.rects[3].height == 10)
    }

    @Test func stackYCursorAdvancesWithoutDivider() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [4.5, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[1].y == 0)
        #expect(result.rects[2].y == 10)
        #expect(result.rects[3].y == 20)
    }

    @Test func dividerSeparatesMasterAndStackColumns() {
        // dividerSize=1: horizontal usable width = 99, master=50 / stack=49.
        let parent = Rect(x: 0, y: 0, width: 100, height: 20)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(result.rects[0] == Rect(x: 0,  y: 0, width: 50, height: 20))
        #expect(result.rects[1] == Rect(x: 51, y: 0, width: 49, height: 20))
    }

    @Test func dividerAlsoSeparatesStackPanes() {
        // 3 stack panes + dividerSize=1 → stack height usable = 30 - 2 = 28.
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 4,
            weights: [1, 1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        // Column split: usable=99, weights [1, 3] → base 24/74, remainder 1 → idx 1 +1
        #expect(result.rects[0].width == 24)    // master
        // Stack heights: distribute(28, [1,1,1]) → base 9/9/9, remainder 1 → idx 0
        #expect(result.rects[1].height == 10)
        #expect(result.rects[2].height == 9)
        #expect(result.rects[3].height == 9)
        // Stack Y cursor: 0, 10+1=11, 11+9+1=21
        #expect(result.rects[1].y == 0)
        #expect(result.rects[2].y == 11)
        #expect(result.rects[3].y == 21)
    }

    @Test func dividerZeroVsOneDiffers() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let d0 = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        let d1 = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [1, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 1
        )
        #expect(d0 != d1)
        // Column totals match parent width vs parent width - 1.
        #expect(d0.rects[0].width + d0.rects[1].width == parent.width)
        #expect(d1.rects[0].width + d1.rects[1].width + 1 == parent.width)
    }

    @Test func minSizeViolationDetected() {
        // Parent too narrow: master 10 cells violates minWidth=20.
        let parent = Rect(x: 0, y: 0, width: 20, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == true)
    }

    @Test func minSizeNotViolatedWhenLargeEnough() {
        let parent = Rect(x: 0, y: 0, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 2,
            weights: [1, 1],
            minSize: Size(width: 20, height: 3),
            dividerSize: 0
        )
        #expect(result.violated == false)
    }

    @Test func originOffsetPreserved() {
        let parent = Rect(x: 10, y: 20, width: 100, height: 30)
        let result = MasterStackSolver.solve(
            parentRect: parent,
            childCount: 3,
            weights: [2, 1, 1],
            minSize: Size(width: 1, height: 1),
            dividerSize: 0
        )
        #expect(result.rects[0].x == 10)
        #expect(result.rects[0].y == 20)
        #expect(result.rects[1].x == 60)   // 10 + 50 master width
        #expect(result.rects[1].y == 20)
        #expect(result.rects[2].y == 35)   // 20 + 15 first stack height
    }
}
