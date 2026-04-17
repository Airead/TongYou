import Testing
@testable import TYTerminal

@Suite("Screen tests", .serialized)
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

    // MARK: - Scrollback segmented growth

    @Test func scrollbackGrowsIncrementally() {
        // maxScrollback=100, initialScrollbackRows=1024 → initial cap should be 100 (< 1024)
        let screen = Screen(columns: 10, rows: 2, maxScrollback: 100)
        // Fill up: writing enough lines to push into scrollback.
        // Each newline when cursor is at bottom pushes top row into scrollback.
        for i in 0..<101 {
            let ch = Character(UnicodeScalar(UInt32(0x41 + (i % 26)))!)
            screen.write(GraphemeCluster(ch), attributes: .default)
            screen.newline()
        }
        #expect(screen.scrollbackCount == 100)
        // Verify content is readable (oldest line should be 'A')
        #expect(screen.scrollbackCell(line: 0, col: 0).codepoint == "A")
    }

    @Test func scrollbackGrowsThroughMultipleSegments() {
        // Use maxScrollback=3000 so we cross several doubling boundaries
        // (1024 → 2048 → 3000).
        let cols = 10
        let screen = Screen(columns: cols, rows: 2, maxScrollback: 3000)
        for i in 0..<3001 {
            let ch = Character(UnicodeScalar(UInt32(0x41 + (i % 26)))!)
            screen.write(GraphemeCluster(ch), attributes: .default)
            screen.newline()
        }
        #expect(screen.scrollbackCount == 3000)
        // First scrollback line should be 'A'
        #expect(screen.scrollbackCell(line: 0, col: 0).codepoint == "A")
        // Last scrollback line
        let lastIdx = 2999
        let expectedCP = UnicodeScalar(UInt32(0x41 + (lastIdx % 26)))!
        #expect(screen.scrollbackCell(line: lastIdx, col: 0).codepoint == Unicode.Scalar(expectedCP))
    }

    @Test func scrollbackRingOverwriteAfterFull() {
        // Small maxScrollback to test ring overwrite after segmented growth completes.
        let screen = Screen(columns: 5, rows: 2, maxScrollback: 10)
        // Write 15 lines — first 5 should be evicted by ring overwrite.
        for i in 0..<16 {
            let ch = Character(UnicodeScalar(UInt32(0x41 + i))!)
            screen.write(GraphemeCluster(ch), attributes: .default)
            screen.newline()
        }
        #expect(screen.scrollbackCount == 10)
        // Oldest visible line should be the 6th character written ('F', i=5)
        #expect(screen.scrollbackCell(line: 0, col: 0).codepoint == "F")
        // Newest visible line should be the 15th character ('O', i=14)
        #expect(screen.scrollbackCell(line: 9, col: 0).codepoint == "O")
    }

    @Test func scrollbackPreservesContentAcrossGrowth() {
        // Verify that data written before a growth event is still accessible after growth.
        let screen = Screen(columns: 5, rows: 2, maxScrollback: 2000)
        // Write exactly 1024 lines (fills initial segment), then 1 more to trigger growth.
        for i in 0..<1026 {
            let ch = Character(UnicodeScalar(UInt32(0x41 + (i % 26)))!)
            screen.write(GraphemeCluster(ch), attributes: .default)
            screen.newline()
        }
        #expect(screen.scrollbackCount == 1025)
        // Check first and last entries survived the growth.
        #expect(screen.scrollbackCell(line: 0, col: 0).codepoint == "A")
        let lastCP = UnicodeScalar(UInt32(0x41 + (1024 % 26)))!
        #expect(screen.scrollbackCell(line: 1024, col: 0).codepoint == Unicode.Scalar(lastCP))
    }
}
