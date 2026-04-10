import Testing
@testable import TongYou

struct SizeTests {

    @Test func gridCalculation() {
        let screen = ScreenSize(width: 1600, height: 1200)
        let cell = CellSize(width: 16, height: 32)
        let grid = GridSize.calculate(screen: screen, cell: cell)
        #expect(grid.columns == 100)
        #expect(grid.rows == 37)
    }

    @Test func paddingBalanced() {
        let screen = ScreenSize(width: 1600, height: 1200)
        let cell = CellSize(width: 16, height: 32)
        let grid = GridSize.calculate(screen: screen, cell: cell)
        let padding = Padding.balanced(screen: screen, grid: grid, cell: cell)

        // Invariant: grid + padding == screen
        let totalW = UInt32(grid.columns) * cell.width + padding.left + padding.right
        let totalH = UInt32(grid.rows) * cell.height + padding.top + padding.bottom
        #expect(totalW == screen.width)
        #expect(totalH == screen.height)

        // Balanced: left/right differ by at most 1
        let diffW = abs(Int32(padding.left) - Int32(padding.right))
        #expect(diffW <= 1)

        // Balanced: top/bottom differ by at most 1
        let diffH = abs(Int32(padding.top) - Int32(padding.bottom))
        #expect(diffH <= 1)
    }

    @Test func minimumGridSize() {
        // Extreme: screen smaller than a single cell
        let screen = ScreenSize(width: 5, height: 5)
        let cell = CellSize(width: 16, height: 32)
        let grid = GridSize.calculate(screen: screen, cell: cell)
        #expect(grid.columns == 1)
        #expect(grid.rows == 1)
    }

    @Test func exactFit() {
        // Screen is exact multiple of cell size — zero padding
        let screen = ScreenSize(width: 1600, height: 1200)
        let cell = CellSize(width: 16, height: 24)
        let grid = GridSize.calculate(screen: screen, cell: cell)
        #expect(grid.columns == 100)
        #expect(grid.rows == 50)

        let padding = Padding.balanced(screen: screen, grid: grid, cell: cell)
        #expect(padding.top == 0)
        #expect(padding.bottom == 0)
        #expect(padding.left == 0)
        #expect(padding.right == 0)
    }

    @Test func paddingInvariantWithOddRemainder() {
        // Odd remainder forces asymmetric but balanced padding
        let screen = ScreenSize(width: 1601, height: 1201)
        let cell = CellSize(width: 16, height: 32)
        let grid = GridSize.calculate(screen: screen, cell: cell)
        let padding = Padding.balanced(screen: screen, grid: grid, cell: cell)

        let totalW = UInt32(grid.columns) * cell.width + padding.left + padding.right
        let totalH = UInt32(grid.rows) * cell.height + padding.top + padding.bottom
        #expect(totalW == screen.width)
        #expect(totalH == screen.height)
    }
}
