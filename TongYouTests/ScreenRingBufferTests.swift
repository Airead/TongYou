import Testing
import TYTerminal
@testable import TongYou

@Suite struct ScreenRingBufferTests {

    // MARK: - Full-screen scroll uses ring rotation

    @Test func fullScreenScrollPreservesContent() {
        let screen = Screen(columns: 5, rows: 3)
        // Fill row 0: "AAAAA", row 1: "BBBBB"
        for _ in 0..<5 { screen.write("A") }
        screen.newline()
        for _ in 0..<5 { screen.write("B") }
        screen.newline()
        for _ in 0..<5 { screen.write("C") }

        // Trigger scroll: writing past last row
        screen.newline()
        for _ in 0..<5 { screen.write("D") }

        // After scroll: row 0 = "BBBBB", row 1 = "CCCCC", row 2 = "DDDDD"
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
        #expect(screen.cell(at: 0, row: 2).codepoint == "D")
        #expect(screen.cursorCol == 4)
        #expect(screen.cursorRow == 2)
    }

    @Test func multipleFullScreenScrolls() {
        let screen = Screen(columns: 3, rows: 2)
        // Write 5 lines to trigger 3 scrolls
        for ch: Unicode.Scalar in ["A", "B", "C", "D", "E"] {
            for _ in 0..<3 { screen.write(ch) }
            if ch != "E" { screen.newline() }
        }

        // After 3 scrolls: row 0 = "DDD", row 1 = "EEE"
        #expect(screen.cell(at: 0, row: 0).codepoint == "D")
        #expect(screen.cell(at: 1, row: 0).codepoint == "D")
        #expect(screen.cell(at: 0, row: 1).codepoint == "E")
    }

    @Test func scrollbackPreservedDuringRingRotation() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }

        // "AAA" should be in scrollback
        #expect(screen.scrollbackCount == 1)
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 1) == "A")
    }

    // MARK: - Snapshot correctness after ring rotation

    @Test func snapshotLinearizesRingBuffer() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        // Scroll once
        screen.newline()
        for _ in 0..<3 { screen.write("C") }

        let snapshot = screen.snapshot()
        // Snapshot cells should be in logical order: row 0 = "BBB", row 1 = "CCC"
        #expect(snapshot.cells[0].codepoint == "B")
        #expect(snapshot.cells[1].codepoint == "B")
        #expect(snapshot.cells[2].codepoint == "B")
        #expect(snapshot.cells[3].codepoint == "C")
        #expect(snapshot.cells[4].codepoint == "C")
        #expect(snapshot.cells[5].codepoint == "C")
    }

    // MARK: - Partial scroll region falls back to physical copy

    @Test func partialScrollRegionWorksWithRingBuffer() {
        let screen = Screen(columns: 3, rows: 4)
        // Fill all 4 rows
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            if ch != "D" { screen.newline() }
        }

        // Set partial scroll region (rows 1-2, leaving row 0 and row 3 fixed)
        screen.setScrollRegion(top: 1, bottom: 2)
        screen.setCursorPos(row: 2, col: 0)
        // Trigger scroll within region
        screen.lineFeed()

        // Row 0 should be unchanged: "AAA"
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        // Row 1 should now have old row 2's content: "CCC"
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
        // Row 2 should be blank (scrolled in)
        #expect(screen.cell(at: 0, row: 2).codepoint == " ")
        // Row 3 should be unchanged: "DDD"
        #expect(screen.cell(at: 0, row: 3).codepoint == "D")
    }

    @Test func fullScreenScrollThenPartialScrollRegion() {
        let screen = Screen(columns: 3, rows: 3)
        // Trigger full-screen scrolls first
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Now ring is rotated. Screen: row 0 = "BBB", row 1 = "CCC", row 2 = "DDD"
        // Wait, let me recalculate. After writing A, B, C, D with newlines:
        // After "A\n": row0=AAA, cursor at (0,1)
        // After "B\n": row0=AAA, row1=BBB, cursor at (0,2)
        // After "C\n": scroll! row0=BBB, row1=CCC, cursor at (0,2)
        // After "D\n": scroll! row0=CCC, row1=DDD, cursor at (0,2)
        // cursor is at (0, 2), but row 2 is blank
        #expect(screen.cell(at: 0, row: 0).codepoint == "C")
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")
        #expect(screen.cell(at: 0, row: 2).codepoint == " ")

        // Now set partial scroll region and scroll within it
        screen.setScrollRegion(top: 0, bottom: 1)
        screen.setCursorPos(row: 1, col: 0)
        screen.lineFeed() // scroll within region [0, 1]

        // Row 0 should have old row 1's content: "DDD"
        #expect(screen.cell(at: 0, row: 0).codepoint == "D")
        // Row 1 should be blank
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
    }

    // MARK: - Erase operations after ring rotation

    @Test func eraseDisplayAfterScroll() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Ring is rotated. Screen: row 0 = "BBB", row 1 = "CCC"

        // Erase entire display
        screen.eraseDisplay(mode: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
    }

    @Test func eraseDisplayBelowAfterScroll() {
        let screen = Screen(columns: 3, rows: 3)
        // Trigger a scroll
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "BBB", row 1 = "CCC", row 2 = "DDD", cursor at (0, 2)

        // Actually after writing D\n, cursor is at col 0, row 2
        // Let me recalculate: 3 rows. Writing A\nB\nC\nD\n:
        // Write "AAA"\n -> row0=AAA, cursor(0,1)
        // Write "BBB"\n -> row0=AAA, row1=BBB, cursor(0,2)
        // Write "CCC"\n -> scroll! row0=BBB, row1=CCC, cursor(0,2)
        // Write "DDD"\n -> scroll! row0=CCC, row1=DDD, cursor(0,2)

        screen.setCursorPos(row: 1, col: 0)
        screen.eraseDisplay(mode: 0) // erase from cursor to end
        #expect(screen.cell(at: 0, row: 0).codepoint == "C")
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
        #expect(screen.cell(at: 0, row: 2).codepoint == " ")
    }

    @Test func eraseLineAfterScroll() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Screen: row 0 = "BBB", row 1 = "CCC"

        screen.setCursorPos(row: 0, col: 1)
        screen.eraseLine(mode: 0) // erase from cursor to end of line
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
        #expect(screen.cell(at: 1, row: 0).codepoint == " ")
        #expect(screen.cell(at: 2, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
    }

    // MARK: - Insert/Delete operations after ring rotation

    @Test func insertCharactersAfterScroll() {
        let screen = Screen(columns: 5, rows: 2)
        for _ in 0..<5 { screen.write("A") }
        screen.newline()
        for _ in 0..<5 { screen.write("B") }
        // Scroll
        screen.newline()
        screen.write("X")
        screen.write("Y")
        screen.write("Z")
        // Screen: row 0 = "BBBBB", row 1 = "XYZ  "

        screen.setCursorPos(row: 1, col: 1)
        screen.insertCharacters(count: 2)
        // Row 1 should be: "X  YZ"
        #expect(screen.cell(at: 0, row: 1).codepoint == "X")
        #expect(screen.cell(at: 1, row: 1).codepoint == " ")
        #expect(screen.cell(at: 2, row: 1).codepoint == " ")
        #expect(screen.cell(at: 3, row: 1).codepoint == "Y")
        #expect(screen.cell(at: 4, row: 1).codepoint == "Z")
    }

    @Test func deleteCharactersAfterScroll() {
        let screen = Screen(columns: 5, rows: 2)
        for _ in 0..<5 { screen.write("A") }
        screen.newline()
        for _ in 0..<5 { screen.write("B") }
        screen.newline()
        screen.write("X")
        screen.write("Y")
        screen.write("Z")
        // Screen: row 0 = "BBBBB", row 1 = "XYZ  "

        screen.setCursorPos(row: 1, col: 1)
        screen.deleteCharacters(count: 1)
        // Row 1 should be: "XZ   "
        #expect(screen.cell(at: 0, row: 1).codepoint == "X")
        #expect(screen.cell(at: 1, row: 1).codepoint == "Z")
        #expect(screen.cell(at: 2, row: 1).codepoint == " ")
    }

    @Test func insertLinesAfterScroll() {
        let screen = Screen(columns: 3, rows: 3)
        // Fill and scroll
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "CCC" (actually "BBB"), hmm let me recalculate
        // 3 rows. After A\nB\nC\nD\n:
        // row0=AAA, row1=BBB, row2=CCC -> scroll -> row0=BBB,row1=CCC -> \nD -> scroll -> row0=CCC,row1=DDD,row2=empty
        #expect(screen.cell(at: 0, row: 0).codepoint == "C")
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")

        // Reset scroll region to full screen
        screen.setScrollRegion(top: 0, bottom: 2)
        screen.setCursorPos(row: 1, col: 0)
        screen.insertLines(count: 1)
        // Row 0 unchanged: "CCC"
        #expect(screen.cell(at: 0, row: 0).codepoint == "C")
        // Row 1 should be blank (inserted)
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
        // Row 2 should have old row 1: "DDD"
        #expect(screen.cell(at: 0, row: 2).codepoint == "D")
    }

    @Test func deleteLinesAfterScroll() {
        let screen = Screen(columns: 3, rows: 3)
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "CCC", row 1 = "DDD", row 2 = empty

        screen.setScrollRegion(top: 0, bottom: 2)
        screen.setCursorPos(row: 0, col: 0)
        screen.deleteLines(count: 1)
        // Row 0 should have old row 1: "DDD"
        #expect(screen.cell(at: 0, row: 0).codepoint == "D")
        // Row 1 should have old row 2: empty
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
        // Row 2 should be blank (vacated)
        #expect(screen.cell(at: 0, row: 2).codepoint == " ")
    }

    // MARK: - Alt screen with ring buffer

    @Test func altScreenPreservesRingState() {
        let screen = Screen(columns: 3, rows: 2)
        // Scroll to rotate ring buffer
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Screen: row 0 = "BBB", row 1 = "CCC" (ring rotated)

        // Switch to alt screen
        screen.switchToAltScreen()
        #expect(screen.cell(at: 0, row: 0).codepoint == " ")
        screen.write("X")

        // Switch back
        screen.switchToMainScreen()
        // Ring state should be restored
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
    }

    // MARK: - Resize with ring buffer

    @Test func resizeUnwrapsRingBuffer() {
        let screen = Screen(columns: 3, rows: 2)
        // Scroll to rotate ring
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Screen: row 0 = "BBB", row 1 = "CCC"

        // Resize wider
        screen.resize(columns: 5, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 3, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
    }

    @Test func resizeWithAltScreenAndRing() {
        let screen = Screen(columns: 3, rows: 2)
        // Scroll main screen
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }

        // Switch to alt, scroll alt
        screen.switchToAltScreen()
        for _ in 0..<3 { screen.write("X") }
        screen.newline()
        for _ in 0..<3 { screen.write("Y") }
        screen.newline()
        for _ in 0..<3 { screen.write("Z") }

        // Resize while on alt screen
        screen.resize(columns: 4, rows: 2)
        // Alt screen should show Y, Z
        #expect(screen.cell(at: 0, row: 0).codepoint == "Y")
        #expect(screen.cell(at: 0, row: 1).codepoint == "Z")

        // Switch back to main
        screen.switchToMainScreen()
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
    }

    // MARK: - Scrollback + ring buffer interaction

    @Test func heavyScrollFillsScrollback() {
        let screen = Screen(columns: 3, rows: 2)
        // Write many lines to fill scrollback
        for i in 0..<20 {
            let ch = Unicode.Scalar(UInt32(0x41 + (i % 26)))!
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Should have scrollback lines
        #expect(screen.scrollbackCount == 19)
        // Verify first scrollback line
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
    }

    @Test func codepointAccessAfterScroll() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Scrollback: "AAA", Screen: "BBB" / "CCC"

        // Absolute line 0 = scrollback "A"
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
        // Absolute line 1 = screen row 0 = "B"
        #expect(screen.codepoint(atAbsoluteLine: 1, col: 0) == "B")
        // Absolute line 2 = screen row 1 = "C"
        #expect(screen.codepoint(atAbsoluteLine: 2, col: 0) == "C")
    }

    // MARK: - Wide characters after ring rotation

    @Test func wideCharAfterScroll() {
        let screen = Screen(columns: 4, rows: 2)
        for _ in 0..<4 { screen.write("A") }
        screen.newline()
        for _ in 0..<4 { screen.write("B") }
        // Scroll
        screen.newline()
        // Write a wide char on the new row
        screen.write(GraphemeCluster(Character("中")), attributes: .default)
        // Wide char should occupy cols 0-1
        #expect(screen.cell(at: 0, row: 1).codepoint == "中")
        #expect(screen.cell(at: 0, row: 1).width == .wide)
        #expect(screen.cell(at: 1, row: 1).width == .continuation)
        // Row 0 should be "BBBB"
        #expect(screen.cell(at: 0, row: 0).codepoint == "B")
    }

    // MARK: - Reverse index with ring buffer

    @Test func reverseIndexAtTopScrollsDown() {
        let screen = Screen(columns: 3, rows: 3)
        // Scroll to rotate ring
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "CCC", row 1 = "DDD", row 2 = empty

        screen.setScrollRegion(top: 0, bottom: 2)
        screen.setCursorPos(row: 0, col: 0)
        screen.reverseIndex()
        // Should scroll down: row 0 = blank, row 1 = "CCC", row 2 = "DDD"
        #expect(screen.cell(at: 0, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
        #expect(screen.cell(at: 0, row: 2).codepoint == "D")
    }

    // MARK: - Extract text after ring rotation

    @Test func extractTextAfterScroll() {
        let screen = Screen(columns: 3, rows: 2)
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }
        // Scrollback: "AAA", Screen: "BBB" / "CCC"

        let sbCount = screen.scrollbackCount
        let sel = Selection(
            start: SelectionPoint(line: sbCount, col: 0),
            end: SelectionPoint(line: sbCount + 1, col: 2),
            mode: .character
        )
        let text = screen.extractText(from: sel)
        #expect(text == "BBB\nCCC")
    }

    // MARK: - Stress: many scrolls

    @Test func manyScrollsProduceCorrectSnapshot() {
        let screen = Screen(columns: 10, rows: 5)
        // Write 100 lines
        for i in 0..<100 {
            let ch = Unicode.Scalar(UInt32(0x30 + (i % 10)))! // '0'-'9'
            for _ in 0..<10 { screen.write(ch) }
            screen.newline()
        }
        // Last 5 visible lines should be lines 96-100
        // Line 96 = '6', line 97 = '7', line 98 = '8', line 99 = '9'
        // (line 100 is the newline after '9', so row 4 is blank)
        // Actually: i=95 -> ch='5', i=96 -> '6', i=97 -> '7', i=98 -> '8', i=99 -> '9'
        // After last newline, cursor is on row 4 (blank)
        #expect(screen.cell(at: 0, row: 0).codepoint == "6")
        #expect(screen.cell(at: 0, row: 1).codepoint == "7")
        #expect(screen.cell(at: 0, row: 2).codepoint == "8")
        #expect(screen.cell(at: 0, row: 3).codepoint == "9")
        #expect(screen.cell(at: 0, row: 4).codepoint == " ")

        // Verify snapshot matches cell access
        let snapshot = screen.snapshot()
        for row in 0..<5 {
            for col in 0..<10 {
                let expected = screen.cell(at: col, row: row)
                let actual = snapshot.cell(at: col, row: row)
                #expect(actual.codepoint == expected.codepoint,
                        "Mismatch at (\(col), \(row)): expected \(expected.codepoint), got \(actual.codepoint)")
            }
        }
    }

    // MARK: - Full reset clears ring state

    @Test func fullResetNormalizesRing() {
        let screen = Screen(columns: 3, rows: 2)
        // Scroll to rotate
        for _ in 0..<3 { screen.write("A") }
        screen.newline()
        for _ in 0..<3 { screen.write("B") }
        screen.newline()
        for _ in 0..<3 { screen.write("C") }

        screen.fullReset()
        #expect(screen.cell(at: 0, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
        #expect(screen.scrollbackCount == 0)
    }

    // MARK: - CSI scroll operations after ring rotation

    @Test func csiScrollUpAfterRingRotation() {
        let screen = Screen(columns: 3, rows: 3)
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "CCC", row 1 = "DDD", row 2 = empty

        screen.scrollUp(count: 1)
        // Row 0 = "DDD", row 1 = empty, row 2 = empty
        #expect(screen.cell(at: 0, row: 0).codepoint == "D")
        #expect(screen.cell(at: 0, row: 1).codepoint == " ")
        #expect(screen.cell(at: 0, row: 2).codepoint == " ")
    }

    @Test func csiScrollDownAfterRingRotation() {
        let screen = Screen(columns: 3, rows: 3)
        for ch: Unicode.Scalar in ["A", "B", "C", "D"] {
            for _ in 0..<3 { screen.write(ch) }
            screen.newline()
        }
        // Screen: row 0 = "CCC", row 1 = "DDD", row 2 = empty

        screen.scrollDown(count: 1)
        // Row 0 = empty, row 1 = "CCC", row 2 = "DDD"
        #expect(screen.cell(at: 0, row: 0).codepoint == " ")
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
        #expect(screen.cell(at: 0, row: 2).codepoint == "D")
    }
}
