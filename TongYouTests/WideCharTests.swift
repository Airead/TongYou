import Testing
import TYTerminal
@testable import TongYou

@Suite struct CharWidthTests {

    @Test func asciiIsNarrow() {
        let a: Unicode.Scalar = "A"
        #expect(a.terminalWidth == 1)
        let space: Unicode.Scalar = " "
        #expect(space.terminalWidth == 1)
    }

    @Test func cjkIsWide() {
        let zhong: Unicode.Scalar = "\u{4E2D}" // 中
        #expect(zhong.terminalWidth == 2)
        let ri: Unicode.Scalar = "\u{65E5}" // 日
        #expect(ri.terminalWidth == 2)
    }

    @Test func hangulIsWide() {
        let ga: Unicode.Scalar = "\u{AC00}" // 가
        #expect(ga.terminalWidth == 2)
    }

    @Test func fullwidthFormIsWide() {
        let fullA: Unicode.Scalar = "\u{FF21}" // Ａ (fullwidth A)
        #expect(fullA.terminalWidth == 2)
    }

    @Test func hiraganaIsWide() {
        let a: Unicode.Scalar = "\u{3042}" // あ
        #expect(a.terminalWidth == 2)
    }

    @Test func katakanaIsWide() {
        let a: Unicode.Scalar = "\u{30A2}" // ア
        #expect(a.terminalWidth == 2)
    }

    @Test func latinExtendedIsNarrow() {
        let e: Unicode.Scalar = "\u{00E9}" // é
        #expect(e.terminalWidth == 1)
    }
}

@Suite struct WideCharScreenTests {

    // MARK: - Basic Write

    @Test func writeWideCharAdvancesByTwo() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中
        #expect(screen.cursorCol == 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation) // continuation
    }

    @Test func writeNarrowAfterWide() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.write("A")        // A at col 2
        #expect(screen.cursorCol == 3)
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 2, row: 0).codepoint == "A")
        #expect(screen.cell(at: 2, row: 0).width == .normal)
    }

    @Test func wideCharWrapsAtLastColumn() {
        // columns=5, write 4 narrow + 1 wide
        let screen = Screen(columns: 5, rows: 2)
        screen.write("A")
        screen.write("B")
        screen.write("C")
        screen.write("D")
        // Cursor at col 4 (last column). Wide char can't fit.
        screen.write("\u{4E2D}")
        // Col 4 of row 0 should be a spacer (wide char boundary padding)
        #expect(screen.cell(at: 4, row: 0).width == .spacer)
        // Wide char on row 1, col 0-1
        #expect(screen.cell(at: 0, row: 1).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 1).width == .wide)
        #expect(screen.cell(at: 1, row: 1).width == .continuation)
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 2)
    }

    // MARK: - Overwrite Cleanup

    @Test func overwriteWideHeadCleansUpContinuation() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.setCursorCol(0)
        screen.write("A") // overwrite head at col 0
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 0, row: 0).width == .normal)
        // Continuation at col 1 should be cleared
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
    }

    @Test func overwriteContinuationCleansUpHead() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.setCursorCol(1)
        screen.write("B") // overwrite continuation at col 1
        // Head at col 0 should be cleared
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 1, row: 0).width == .normal)
    }

    @Test func overwriteWideWithWide() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.setCursorCol(0)
        screen.write("\u{65E5}") // 日 at col 0-1
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{65E5}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
    }

    @Test func wideCharOverwritesMidwayBetweenTwoWides() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.write("\u{65E5}") // 日 at col 2-3
        // Write wide at col 1 — should destroy both
        screen.setCursorCol(1)
        screen.write("X")
        // Col 0 head orphaned → cleared
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0).codepoint == "X")
        #expect(screen.cell(at: 1, row: 0).width == .normal)
        // Col 2-3 should still be intact (we only wrote at col 1)
        #expect(screen.cell(at: 2, row: 0).codepoint == "\u{65E5}")
    }

    // MARK: - Erase Operations

    @Test func eraseLineRightRepairsWideAtBoundary() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.write("\u{65E5}") // 日 at col 2-3
        // Erase from col 1 (middle of first wide char)
        screen.setCursorCol(1)
        screen.eraseLine(mode: 0)
        // Col 0 was a wide head, but col 1+ erased — head should be cleared
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
    }

    @Test func eraseLineLeftRepairsWideAtBoundary() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("A")
        screen.write("\u{4E2D}") // 中 at col 1-2
        // Erase from start to col 1 (head of wide char)
        screen.setCursorCol(1)
        screen.eraseLine(mode: 1)
        // Col 1 (head) is erased. Col 2 (continuation) should also be cleared.
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
    }

    @Test func eraseCharactersRepairsWideBoundary() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.write("\u{65E5}") // 日 at col 2-3
        screen.write("A")        // A at col 4
        // Erase 2 chars from col 1
        screen.setCursorCol(1)
        screen.eraseCharacters(count: 2)
        // Col 0 head orphaned → cleared
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        // Col 3 continuation orphaned → cleared
        #expect(screen.cell(at: 3, row: 0) == Cell.empty)
        #expect(screen.cell(at: 4, row: 0).codepoint == "A")
    }

    // MARK: - Insert / Delete

    @Test func insertCharactersShiftsWideChar() {
        let screen = Screen(columns: 8, rows: 1)
        screen.write("\u{4E2D}") // 中 at col 0-1
        screen.write("\u{65E5}") // 日 at col 2-3
        screen.setCursorCol(0)
        screen.insertCharacters(count: 1)
        // Col 0 should be blank, 中 shifted to col 1-2
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 1, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 1, row: 0).width == .wide)
        #expect(screen.cell(at: 2, row: 0).width == .continuation)
    }

    @Test func deleteCharactersWithWideChar() {
        let screen = Screen(columns: 8, rows: 1)
        screen.write("A")
        screen.write("\u{4E2D}") // 中 at col 1-2
        screen.write("B")        // B at col 3
        screen.setCursorCol(0)
        screen.deleteCharacters(count: 1)
        // 中 should shift left to col 0-1
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 2, row: 0).codepoint == "B")
    }

    // MARK: - Resize

    @Test func resizeReflowsWideCharAtBoundary() {
        let screen = Screen(columns: 6, rows: 1)
        screen.write("A")
        screen.write("B")
        screen.write("\u{4E2D}") // 中 at col 2-3
        screen.write("C")
        // Resize to 3 columns — wide char doesn't fit in remaining 1 col,
        // reflow wraps it to a new line. "AB" goes to scrollback, "中C" is active.
        screen.resize(columns: 3, rows: 1)
        #expect(screen.columns == 3)
        // Active screen shows the last row of reflowed content
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
        // "AB" is in scrollback
        #expect(screen.scrollbackCount == 1)
    }

    // MARK: - Extract Text

    @Test func extractTextSkipsContinuation() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中
        screen.write("A")

        let sel = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 0, col: 2)
        )
        let text = screen.extractText(from: sel)
        #expect(text == "中A")
    }

    @Test func extractTextMultipleWideChars() {
        let screen = Screen(columns: 10, rows: 1)
        screen.write("\u{4E2D}") // 中
        screen.write("\u{65E5}") // 日
        screen.write("\u{672C}") // 本

        let sel = Selection(
            start: SelectionPoint(line: 0, col: 0),
            end: SelectionPoint(line: 0, col: 5)
        )
        let text = screen.extractText(from: sel)
        #expect(text == "中日本")
    }

    // MARK: - Edge Cases

    @Test func wideCharFillsExactly() {
        // 4-column screen, write 2 wide chars = exactly fills
        let screen = Screen(columns: 4, rows: 1)
        screen.write("\u{4E2D}") // col 0-1
        screen.write("\u{65E5}") // col 2-3
        #expect(screen.cursorCol == 4) // past end, next write wraps
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 2, row: 0).width == .wide)
        #expect(screen.cell(at: 3, row: 0).width == .continuation)
    }

    @Test func wideCharOnOddWidthScreen() {
        // 3-column screen: wide char at col 0, then another at col 2 won't fit
        let screen = Screen(columns: 3, rows: 2)
        screen.write("\u{4E2D}") // col 0-1
        // cursor at col 2, which is columns-1. Wide char wraps.
        screen.write("\u{65E5}")
        #expect(screen.cell(at: 2, row: 0).width == .spacer) // padding
        #expect(screen.cell(at: 0, row: 1).codepoint == "\u{65E5}")
        #expect(screen.cell(at: 0, row: 1).width == .wide)
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 2)
    }

    // MARK: - Wide Char Reflow

    @Test func reflowChineseRepeatedResizeNoExtraSpaces() {
        // Simulate repeated resize — Chinese chars must not accumulate spaces
        let screen = Screen(columns: 10, rows: 2)
        // "中文测试字" = 5 wide chars = 10 columns (exactly fills row)
        screen.write("\u{4E2D}") // 中
        screen.write("\u{6587}") // 文
        screen.write("\u{6D4B}") // 测
        screen.write("\u{8BD5}") // 试
        screen.write("\u{5B57}") // 字
        // Row 0: [中,cont,文,cont,测,cont,试,cont,字,cont] cursorCol=10

        // Resize down to 7 cols, then back to 10 — repeat 5 times
        for _ in 0..<5 {
            screen.resize(columns: 7, rows: 2)
            screen.resize(columns: 10, rows: 2)
        }

        // After repeated reflow, content must be identical to original
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 2, row: 0).codepoint == "\u{6587}")
        #expect(screen.cell(at: 4, row: 0).codepoint == "\u{6D4B}")
        #expect(screen.cell(at: 6, row: 0).codepoint == "\u{8BD5}")
        #expect(screen.cell(at: 8, row: 0).codepoint == "\u{5B57}")
        // No spurious spaces — all cells accounted for
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 3, row: 0).width == .continuation)
    }

    @Test func reflowChineseWithSpacerAtBoundary() {
        // 7-col screen: "中文测" = 6 cols, then "试" needs 2 cols but only 1 remains → spacer
        let screen = Screen(columns: 7, rows: 2)
        screen.write("\u{4E2D}") // 中 col 0-1
        screen.write("\u{6587}") // 文 col 2-3
        screen.write("\u{6D4B}") // 测 col 4-5
        screen.write("\u{8BD5}") // 试 — doesn't fit at col 6, spacer + wrap
        // Row 0: [中,cont,文,cont,测,cont,spacer], wrapped
        // Row 1: [试,cont,empty,...]
        #expect(screen.cell(at: 6, row: 0).width == .spacer)
        #expect(screen.cell(at: 0, row: 1).codepoint == "\u{8BD5}")

        // Resize to 10 — should unwrap cleanly
        screen.resize(columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 2, row: 0).codepoint == "\u{6587}")
        #expect(screen.cell(at: 4, row: 0).codepoint == "\u{6D4B}")
        #expect(screen.cell(at: 6, row: 0).codepoint == "\u{8BD5}")
        // No spacer or extra space between 测 and 试
        #expect(screen.cell(at: 5, row: 0).width == .continuation) // 测's continuation
        #expect(screen.cell(at: 7, row: 0).width == .continuation) // 试's continuation
    }

    @Test func reflowMixedChineseEnglishRepeated() {
        let screen = Screen(columns: 8, rows: 2)
        // "A中B文C" = 1+2+1+2+1 = 7 columns
        screen.write("A")
        screen.write("\u{4E2D}")
        screen.write("B")
        screen.write("\u{6587}")
        screen.write("C")

        // Repeated resize cycle
        for _ in 0..<5 {
            screen.resize(columns: 5, rows: 2)
            screen.resize(columns: 8, rows: 2)
        }

        // Content should be exactly "A中B文C" with no extra spaces
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "\u{4E2D}")
        #expect(screen.cell(at: 1, row: 0).width == .wide)
        #expect(screen.cell(at: 3, row: 0).codepoint == "B")
        #expect(screen.cell(at: 4, row: 0).codepoint == "\u{6587}")
        #expect(screen.cell(at: 4, row: 0).width == .wide)
        #expect(screen.cell(at: 6, row: 0).codepoint == "C")
    }
}
