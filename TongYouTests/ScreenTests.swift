import Testing
import TYTerminal
@testable import TongYou

@Suite struct ScreenTests {

    @Test func initialState() {
        let screen = Screen(columns: 80, rows: 24)
        #expect(screen.columns == 80)
        #expect(screen.rows == 24)
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 79, row: 23) == Cell.empty)
    }

    @Test func writeCharacter() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cursorCol == 1)
        #expect(screen.cursorRow == 0)
    }

    @Test func writeMultipleCharacters() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("H")
        screen.write("i")
        #expect(screen.cell(at: 0, row: 0).codepoint == "H")
        #expect(screen.cell(at: 1, row: 0).codepoint == "i")
        #expect(screen.cursorCol == 2)
    }

    @Test func lineWrap() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A")
        screen.write("B")
        screen.write("C")
        // Cursor is at col 3, which is past columns
        // Next write should wrap to next line
        screen.write("D")
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")
        #expect(screen.cursorCol == 1)
        #expect(screen.cursorRow == 1)
    }

    @Test func lineFeed() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        screen.lineFeed()
        #expect(screen.cursorCol == 1)
        #expect(screen.cursorRow == 1)
    }

    @Test func carriageReturn() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        screen.write("B")
        screen.carriageReturn()
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
    }

    @Test func newline() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        screen.newline()
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 1)
    }

    @Test func scrollUpAtBottom() {
        let screen = Screen(columns: 3, rows: 2)
        // Fill first row
        screen.write("A")
        screen.write("B")
        screen.write("C")
        // Move to second row
        screen.newline()
        screen.write("D")
        screen.write("E")
        screen.write("F")
        // Trigger scroll by going past bottom
        screen.newline()
        // First row should now contain what was the second row
        #expect(screen.cell(at: 0, row: 0).codepoint == "D")
        #expect(screen.cell(at: 1, row: 0).codepoint == "E")
        #expect(screen.cell(at: 2, row: 0).codepoint == "F")
        // Second row should be cleared
        #expect(screen.cell(at: 0, row: 1) == Cell.empty)
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 0)
    }

    @Test func backspace() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        screen.write("B")
        screen.backspace()
        #expect(screen.cursorCol == 1)
        // Backspace does not erase, only moves cursor
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
    }

    @Test func backspaceAtColumnZero() {
        let screen = Screen(columns: 80, rows: 24)
        screen.backspace()
        #expect(screen.cursorCol == 0)
    }

    @Test func backspaceMarksDirtyRegion() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("a")
        screen.write("d")
        screen.write(" ")
        screen.write(" ")
        // Clear dirty state from writes
        _ = screen.snapshot()
        // Backspace over a space should mark the cursor row dirty
        screen.backspace()
        #expect(screen.cursorCol == 3)
        #expect(screen.dirtyRegion.lineRange != nil)
        #expect(screen.dirtyRegion.lineRange!.contains(0))
    }

    @Test func backspaceAtColumnZeroDoesNotMarkDirty() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.snapshot()
        screen.backspace()
        #expect(screen.cursorCol == 0)
        #expect(screen.dirtyRegion.lineRange == nil)
    }

    @Test func tab() {
        let screen = Screen(columns: 80, rows: 24)
        screen.write("A")
        screen.tab()
        #expect(screen.cursorCol == 8)
    }

    @Test func tabFromTabStop() {
        let screen = Screen(columns: 80, rows: 24)
        // Move cursor to col 8
        for _ in 0..<8 { screen.write(" ") }
        screen.tab()
        #expect(screen.cursorCol == 16)
    }

    @Test func tabClampsToLastColumn() {
        let screen = Screen(columns: 10, rows: 1)
        // At col 0, tab to 8
        screen.tab()
        #expect(screen.cursorCol == 8)
        // Tab again should clamp to 9 (last column)
        screen.tab()
        #expect(screen.cursorCol == 9)
    }

    @Test func resizeGrow() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A")
        screen.write("B")
        screen.resize(columns: 5, rows: 3)
        #expect(screen.columns == 5)
        #expect(screen.rows == 3)
        // Existing content preserved
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        // New cells are empty
        #expect(screen.cell(at: 3, row: 0) == Cell.empty)
        #expect(screen.cell(at: 0, row: 2) == Cell.empty)
    }

    @Test func resizeShrink() {
        let screen = Screen(columns: 5, rows: 3)
        screen.write("A")
        screen.write("B")
        screen.write("C")
        screen.write("D")
        screen.write("E")
        screen.resize(columns: 3, rows: 2)
        #expect(screen.columns == 3)
        #expect(screen.rows == 2)
        // Content within new bounds preserved
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
    }

    @Test func resizeClamsCursor() {
        let screen = Screen(columns: 10, rows: 10)
        // Move cursor to (5, 5)
        for _ in 0..<5 { screen.write(" ") }
        for _ in 0..<5 { screen.lineFeed() }
        #expect(screen.cursorCol == 5)
        #expect(screen.cursorRow == 5)
        // Shrink to 3x3
        screen.resize(columns: 3, rows: 3)
        #expect(screen.cursorCol == 2)
        #expect(screen.cursorRow == 2)
    }

    @Test func snapshot() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("X")
        let snap = screen.snapshot()
        #expect(snap.columns == 3)
        #expect(snap.rows == 2)
        #expect(snap.cursorCol == 1)
        #expect(snap.cursorRow == 0)
        #expect(snap.cell(at: 0, row: 0).codepoint == "X")
        #expect(snap.cell(at: 1, row: 0) == Cell.empty)
    }

    @Test func clear() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A")
        screen.write("B")
        screen.clear()
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
    }

    @Test func minimumSize() {
        let screen = Screen(columns: 0, rows: 0)
        #expect(screen.columns == 1)
        #expect(screen.rows == 1)
    }

    @Test func lineWrapWithScroll() {
        let screen = Screen(columns: 2, rows: 2)
        // Fill entire screen
        screen.write("A")
        screen.write("B")
        screen.newline()
        screen.write("C")
        screen.write("D")
        // Now write one more character — should wrap + scroll
        screen.write("E")
        // Row 0 should be what was row 1 (C, D)
        #expect(screen.cell(at: 0, row: 0).codepoint == "C")
        #expect(screen.cell(at: 1, row: 0).codepoint == "D")
        // Row 1 should have E at col 0
        #expect(screen.cell(at: 0, row: 1).codepoint == "E")
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 1)
    }

    // MARK: - Cursor Movement

    @Test func cursorUp() {
        let screen = Screen(columns: 10, rows: 10)
        screen.setCursorPos(row: 5, col: 3)
        screen.cursorUp(2)
        #expect(screen.cursorRow == 3)
        #expect(screen.cursorCol == 3)
    }

    @Test func cursorUpClampsAtTop() {
        let screen = Screen(columns: 10, rows: 10)
        screen.setCursorPos(row: 1, col: 0)
        screen.cursorUp(5)
        #expect(screen.cursorRow == 0)
    }

    @Test func cursorDown() {
        let screen = Screen(columns: 10, rows: 10)
        screen.cursorDown(3)
        #expect(screen.cursorRow == 3)
    }

    @Test func cursorForwardBackward() {
        let screen = Screen(columns: 10, rows: 5)
        screen.cursorForward(4)
        #expect(screen.cursorCol == 4)
        screen.cursorBackward(2)
        #expect(screen.cursorCol == 2)
    }

    @Test func setCursorPos() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 10, col: 20)
        #expect(screen.cursorRow == 10)
        #expect(screen.cursorCol == 20)
    }

    @Test func setCursorPosClamps() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setCursorPos(row: 100, col: 100)
        #expect(screen.cursorRow == 4)
        #expect(screen.cursorCol == 9)
    }

    // MARK: - Erase Operations

    @Test func eraseDisplayBelow() {
        let screen = Screen(columns: 3, rows: 3)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E", "F", "G", "H", "I"] {
            screen.write(c)
        }
        screen.setCursorPos(row: 1, col: 1)
        screen.eraseDisplay(mode: 0)
        // Row 0 intact
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        // Row 1, col 0 intact; col 1 and beyond erased
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")
        #expect(screen.cell(at: 1, row: 1) == Cell.empty)
        #expect(screen.cell(at: 2, row: 1) == Cell.empty)
        // Row 2 erased
        #expect(screen.cell(at: 0, row: 2) == Cell.empty)
    }

    @Test func eraseDisplayAll() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A")
        screen.write("B")
        screen.eraseDisplay(mode: 2)
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
    }

    @Test func eraseLineRight() {
        let screen = Screen(columns: 5, rows: 1)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E"] { screen.write(c) }
        screen.setCursorCol(2)
        screen.eraseLine(mode: 0)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        #expect(screen.cell(at: 3, row: 0) == Cell.empty)
    }

    @Test func eraseLineLeft() {
        let screen = Screen(columns: 5, rows: 1)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E"] { screen.write(c) }
        screen.setCursorCol(2)
        screen.eraseLine(mode: 1)
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        #expect(screen.cell(at: 3, row: 0).codepoint == "D")
    }

    @Test func eraseCharacters() {
        let screen = Screen(columns: 5, rows: 1)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E"] { screen.write(c) }
        screen.setCursorCol(1)
        screen.eraseCharacters(count: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        #expect(screen.cell(at: 3, row: 0).codepoint == "D")
    }

    // MARK: - Scroll Region

    @Test func scrollRegion() {
        let screen = Screen(columns: 3, rows: 4)
        // Fill rows: row0=ABC, row1=DEF, row2=GHI, row3=JKL
        for c: Unicode.Scalar in ["A","B","C"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["D","E","F"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["G","H","I"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["J","K","L"] { screen.write(c) }

        // Set scroll region to rows 1-2
        screen.setScrollRegion(top: 1, bottom: 2)
        screen.setCursorPos(row: 2, col: 0)
        // Scroll up within region
        screen.scrollUp()
        // Row 0 (outside region) unchanged
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        // Row 1 should now have what was row 2
        #expect(screen.cell(at: 0, row: 1).codepoint == "G")
        // Row 2 should be cleared
        #expect(screen.cell(at: 0, row: 2) == Cell.empty)
        // Row 3 (outside region) unchanged
        #expect(screen.cell(at: 0, row: 3).codepoint == "J")
    }

    @Test func reverseIndex() {
        let screen = Screen(columns: 3, rows: 3)
        screen.write("A"); screen.write("B"); screen.write("C")
        screen.newline()
        screen.write("D"); screen.write("E"); screen.write("F")
        // Cursor at row 1. Set scroll region full.
        screen.setScrollRegion(top: 0, bottom: 2)
        screen.setCursorPos(row: 0, col: 0)
        // Reverse index at top should scroll down
        screen.reverseIndex()
        // Row 0 should be cleared (scrolled down)
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        // Row 1 should have what was row 0
        #expect(screen.cell(at: 0, row: 1).codepoint == "A")
    }

    // MARK: - Insert / Delete

    @Test func insertCharacters() {
        let screen = Screen(columns: 5, rows: 1)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E"] { screen.write(c) }
        screen.setCursorCol(1)
        screen.insertCharacters(count: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        #expect(screen.cell(at: 3, row: 0).codepoint == "B")
        #expect(screen.cell(at: 4, row: 0).codepoint == "C")
    }

    @Test func deleteCharacters() {
        let screen = Screen(columns: 5, rows: 1)
        for c: Unicode.Scalar in ["A", "B", "C", "D", "E"] { screen.write(c) }
        screen.setCursorCol(1)
        screen.deleteCharacters(count: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "D")
        #expect(screen.cell(at: 2, row: 0).codepoint == "E")
        #expect(screen.cell(at: 3, row: 0) == Cell.empty)
        #expect(screen.cell(at: 4, row: 0) == Cell.empty)
    }

    @Test func insertLines() {
        let screen = Screen(columns: 2, rows: 3)
        screen.write("A"); screen.write("B"); screen.newline()
        screen.write("C"); screen.write("D"); screen.newline()
        screen.write("E"); screen.write("F")
        screen.setCursorPos(row: 1, col: 0)
        screen.insertLines(count: 1)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 0, row: 1) == Cell.empty) // inserted blank
        #expect(screen.cell(at: 0, row: 2).codepoint == "C") // pushed down
    }

    @Test func deleteLines() {
        let screen = Screen(columns: 2, rows: 3)
        screen.write("A"); screen.write("B"); screen.newline()
        screen.write("C"); screen.write("D"); screen.newline()
        screen.write("E"); screen.write("F")
        screen.setCursorPos(row: 1, col: 0)
        screen.deleteLines(count: 1)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 0, row: 1).codepoint == "E") // pulled up
        #expect(screen.cell(at: 0, row: 2) == Cell.empty)    // cleared
    }

    // MARK: - Alternate Screen

    @Test func altScreen() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A"); screen.write("B")
        screen.switchToAltScreen()
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        screen.write("X")
        screen.switchToMainScreen()
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
    }

    // MARK: - Resize with Alternate Screen

    @Test func resizeGrowWhileOnAltScreen() {
        let screen = Screen(columns: 4, rows: 3)
        // Write content on main screen
        screen.write("A"); screen.write("B"); screen.write("C")
        screen.setCursorPos(row: 1, col: 2)

        // Switch to alt screen (simulates htop start)
        screen.switchToAltScreen()

        // Enlarge window while on alt screen
        screen.resize(columns: 6, rows: 5)
        #expect(screen.columns == 6)
        #expect(screen.rows == 5)

        // Switch back to main screen (simulates htop exit)
        screen.switchToMainScreen()

        // Must not crash — cells.count must equal columns * rows
        let snap = screen.snapshot()
        #expect(snap.cells.count == 6 * 5)
        #expect(snap.columns == 6)
        #expect(snap.rows == 5)

        // Original content preserved within old bounds
        #expect(snap.cell(at: 0, row: 0).codepoint == "A")
        #expect(snap.cell(at: 1, row: 0).codepoint == "B")
        #expect(snap.cell(at: 2, row: 0).codepoint == "C")

        // New cells are empty
        #expect(snap.cell(at: 4, row: 0) == Cell.empty)
        #expect(snap.cell(at: 0, row: 3) == Cell.empty)

        // Operations after restore must not crash
        screen.eraseDisplay(mode: 2)
        screen.setCursorPos(row: 0, col: 0)
        screen.write("Z")
        #expect(screen.cell(at: 0, row: 0).codepoint == "Z")
    }

    @Test func resizeShrinkWhileOnAltScreen() {
        let screen = Screen(columns: 6, rows: 5)
        screen.write("A"); screen.write("B"); screen.write("C")
        screen.setCursorPos(row: 3, col: 4)

        screen.switchToAltScreen()

        // Shrink window while on alt screen
        screen.resize(columns: 3, rows: 2)

        screen.switchToMainScreen()

        let snap = screen.snapshot()
        #expect(snap.cells.count == 3 * 2)
        #expect(snap.columns == 3)
        #expect(snap.rows == 2)

        // Content within new bounds preserved
        #expect(snap.cell(at: 0, row: 0).codepoint == "A")
        #expect(snap.cell(at: 1, row: 0).codepoint == "B")
        #expect(snap.cell(at: 2, row: 0).codepoint == "C")

        // Cursor clamped to new bounds
        #expect(screen.cursorCol <= 2)
        #expect(screen.cursorRow <= 1)

        // Operations after restore must not crash
        screen.eraseDisplay(mode: 0)
        screen.write("Z")
    }

    @Test func multipleResizesWhileOnAltScreen() {
        let screen = Screen(columns: 4, rows: 3)
        screen.write("X")
        screen.switchToAltScreen()

        // Multiple resizes
        screen.resize(columns: 8, rows: 6)
        screen.resize(columns: 5, rows: 4)

        screen.switchToMainScreen()

        let snap = screen.snapshot()
        #expect(snap.cells.count == 5 * 4)
        #expect(snap.cell(at: 0, row: 0).codepoint == "X")

        // Must not crash
        screen.setCursorPos(row: 3, col: 4)
        screen.write("Y")
    }

    // MARK: - Backward Tab

    @Test func backwardTab() {
        let screen = Screen(columns: 20, rows: 1)
        screen.setCursorCol(10)
        screen.backwardTab(count: 1)
        #expect(screen.cursorCol == 8)
        screen.backwardTab(count: 1)
        #expect(screen.cursorCol == 0)
    }

    // MARK: - Reflow

    @Test func reflowShrinkPreservesContent() {
        // "ABCDEFGH" on a 8-col screen, resize to 4 cols
        let screen = Screen(columns: 8, rows: 2)
        for c: Unicode.Scalar in ["A","B","C","D","E","F","G","H"] { screen.write(c) }
        screen.resize(columns: 4, rows: 2)
        // Should reflow: row 0 = ABCD (wrapped), row 1 = EFGH
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 3, row: 0).codepoint == "D")
        #expect(screen.cell(at: 0, row: 1).codepoint == "E")
        #expect(screen.cell(at: 3, row: 1).codepoint == "H")
    }

    @Test func reflowGrowUnwrapsContent() {
        // Write 8 chars on a 4-col screen (wraps to 2 lines), then widen to 8 cols
        let screen = Screen(columns: 4, rows: 2)
        for c: Unicode.Scalar in ["A","B","C","D","E","F","G","H"] { screen.write(c) }
        // At 4 cols: row 0 = ABCD (wrapped), row 1 = EFGH
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 0, row: 1).codepoint == "E")
        // Widen to 8 cols — should unwrap back to single line
        screen.resize(columns: 8, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 4, row: 0).codepoint == "E")
        #expect(screen.cell(at: 7, row: 0).codepoint == "H")
        // Second row should be empty after unwrap
        #expect(screen.cell(at: 0, row: 1) == Cell.empty)
    }

    @Test func reflowPreservesCursorPosition() {
        let screen = Screen(columns: 10, rows: 3)
        for c: Unicode.Scalar in ["A","B","C","D","E"] { screen.write(c) }
        // Cursor at (0, 5)
        #expect(screen.cursorCol == 5)
        #expect(screen.cursorRow == 0)
        screen.resize(columns: 4, rows: 3)
        // "ABCDE" reflows to "ABCD"(wrapped) + "E". Cursor was at col 5 → maps to row 1, col 1
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 1)
    }

    @Test func reflowScrollbackToScreen() {
        // Fill scrollback, then widen so lines fit in fewer rows → scrollback pulled back
        let screen = Screen(columns: 4, rows: 2)
        // Write 3 lines of 4 chars
        for c: Unicode.Scalar in ["A","B","C","D"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["E","F","G","H"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["I","J","K","L"] { screen.write(c) }
        // Row 0 ("ABCD") should be in scrollback after 3 newlines on 2-row screen
        #expect(screen.scrollbackCount == 1)
        // Now widen — content still fits in 4 cols (no reflow change),
        // but with more columns, same number of rows
        screen.resize(columns: 8, rows: 3)
        // With 3 rows now, scrollback content can be pulled into active screen
        // (since only 3 logical lines exist and we have 3 screen rows)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 0, row: 1).codepoint == "E")
        #expect(screen.cell(at: 0, row: 2).codepoint == "I")
    }

    @Test func reflowMultipleLinesWithHardBreaks() {
        // Multiple hard-break lines, shrink columns
        let screen = Screen(columns: 6, rows: 4)
        for c: Unicode.Scalar in ["A","B","C"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["D","E","F","G","H","I"] { screen.write(c) }
        screen.newline()
        // Row 0: "ABC", Row 1: "DEFGHI", Row 2: empty, cursor at (2, 0)
        screen.resize(columns: 3, rows: 4)
        // "ABC" stays on 1 row. "DEFGHI" wraps to "DEF"+"GHI" (2 rows)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")
        #expect(screen.cell(at: 2, row: 1).codepoint == "F")
        #expect(screen.cell(at: 0, row: 2).codepoint == "G")
        #expect(screen.cell(at: 2, row: 2).codepoint == "I")
    }

    // MARK: - Extract Text Unwrap

    @Test func extractTextUnwrapsSoftWrappedLines() {
        let screen = Screen(columns: 4, rows: 2)
        // Write "ABCDEFGH" — wraps at col 4
        for c: Unicode.Scalar in ["A","B","C","D","E","F","G","H"] { screen.write(c) }
        // Row 0 = "ABCD" (wrapped), Row 1 = "EFGH"
        let sbCount = screen.scrollbackCount
        let sel = Selection(
            start: SelectionPoint(line: sbCount + 0, col: 0),
            end: SelectionPoint(line: sbCount + 1, col: 3)
        )
        let text = screen.extractText(from: sel)
        // Soft-wrapped lines should NOT have a newline between them
        #expect(text == "ABCDEFGH")
    }

    @Test func extractTextKeepsHardBreaks() {
        let screen = Screen(columns: 4, rows: 3)
        for c: Unicode.Scalar in ["A","B"] { screen.write(c) }
        screen.newline()
        for c: Unicode.Scalar in ["C","D"] { screen.write(c) }
        let sbCount = screen.scrollbackCount
        let sel = Selection(
            start: SelectionPoint(line: sbCount + 0, col: 0),
            end: SelectionPoint(line: sbCount + 1, col: 1)
        )
        let text = screen.extractText(from: sel)
        // Hard break → newline in output
        #expect(text == "AB\nCD")
    }

    @Test func wrappedFlagSetOnAutoWrap() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A"); screen.write("B"); screen.write("C")
        // Cursor at col 3. Not yet wrapped — flag not set until next write triggers wrap.
        #expect(!screen.isLineWrapped(absoluteLine: 0))
        // Writing one more char triggers the wrap
        screen.write("D")
        #expect(screen.isLineWrapped(absoluteLine: 0))
        #expect(screen.cell(at: 0, row: 1).codepoint == "D")
    }

    @Test func wrappedFlagClearedByEraseLine() {
        let screen = Screen(columns: 3, rows: 2)
        screen.write("A"); screen.write("B"); screen.write("C")
        screen.write("D") // triggers wrap, row 0 wrapped=true
        #expect(screen.isLineWrapped(absoluteLine: 0))
        // Erase line right on row 0 should clear the wrapped flag
        screen.setCursorPos(row: 0, col: 0)
        screen.eraseLine(mode: 0)
        #expect(!screen.isLineWrapped(absoluteLine: 0))
    }

    // MARK: - DECDHL / DECDWL Line Size

    @Test func setLineSizeDECDHLTop() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setLineSize(height: .doubleTop, width: .double)
        let snapshot = screen.snapshot()
        #expect(snapshot.lineFlags[0].lineHeight == .doubleTop)
        #expect(snapshot.lineFlags[0].lineWidth == .double)
    }

    @Test func setLineSizeDECDHLBottom() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        screen.setLineSize(height: .doubleBottom, width: .double)
        let snapshot = screen.snapshot()
        #expect(snapshot.lineFlags[5].lineHeight == .doubleBottom)
        #expect(snapshot.lineFlags[5].lineWidth == .double)
    }

    @Test func setLineSizeNormal() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setLineSize(height: .normal, width: .normal)
        let snapshot = screen.snapshot()
        #expect(snapshot.lineFlags[0].lineHeight == .normal)
        #expect(snapshot.lineFlags[0].lineWidth == .normal)
    }

    @Test func setLineSizeDECDWL() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 3, col: 0)
        screen.setLineSize(height: .normal, width: .double)
        let snapshot = screen.snapshot()
        #expect(snapshot.lineFlags[3].lineHeight == .normal)
        #expect(snapshot.lineFlags[3].lineWidth == .double)
    }

    @Test func setLineSizeMarksRowDirty() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setLineSize(height: .doubleTop, width: .double)
        let region = screen.consumeDirtyRegion()
        #expect(region.isDirty(row: 0))
    }
}
