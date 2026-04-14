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

    @Test func writeEmojiSequenceUsesCorrectWidth() {
        let screen = Screen(columns: 10, rows: 2)

        // ZWJ sequence should take 2 cells, not 7
        screen.write(GraphemeCluster(Character("👨‍👩‍👧‍👦")), attributes: .default)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cursorCol == 2)

        // Skin tone modifier stays 2 cells
        screen.write(GraphemeCluster(Character("👋🏻")), attributes: .default)
        #expect(screen.cell(at: 2, row: 0).width == .wide)
        #expect(screen.cell(at: 3, row: 0).width == .continuation)

        // Flag stays 2 cells
        screen.write(GraphemeCluster(Character("🇨🇳")), attributes: .default)
        #expect(screen.cell(at: 4, row: 0).width == .wide)
        #expect(screen.cell(at: 5, row: 0).width == .continuation)

        // ASCII stays 1 cell
        screen.write(GraphemeCluster(Character("A")), attributes: .default)
        #expect(screen.cell(at: 6, row: 0).width == .normal)
        #expect(screen.cursorCol == 7)
    }

    @Test func wideEmojiSpacerAtLastColumn() {
        let screen = Screen(columns: 3, rows: 2)
        screen.setCursorPos(row: 0, col: 2)

        screen.write(GraphemeCluster(Character("🇨🇳")), attributes: .default)
        // Should leave spacer at col 2 and wrap
        #expect(screen.cell(at: 2, row: 0).width == .spacer)
        #expect(screen.cell(at: 0, row: 1).width == .wide)
        #expect(screen.cell(at: 1, row: 1).width == .continuation)
    }
}
