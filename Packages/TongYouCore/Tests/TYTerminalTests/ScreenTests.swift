import Testing
@testable import TYTerminal

@Suite("Screen tests")
struct ScreenTests {

    @Test func initializesWithCorrectDimensions() {
        let screen = Screen(columns: 80, rows: 24)
        #expect(screen.columns == 80)
        #expect(screen.rows == 24)
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorVisible == true)
    }

    @Test func dirtyRegionMarkLine() {
        var region = DirtyRegion.clean
        region.markLine(5)
        #expect(region.lineRange == 5..<6)
        region.markLine(3)
        #expect(region.lineRange == 3..<6)
        region.markLine(8)
        #expect(region.lineRange == 3..<9)
    }

    @Test func dirtyRegionFullRebuildIgnoresMarkLine() {
        var region = DirtyRegion.full
        region.markLine(5)
        #expect(region.fullRebuild == true)
        #expect(region.lineRange == nil)
    }
}
