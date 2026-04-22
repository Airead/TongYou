import Testing
@testable import TongYou

struct ScrollbackTests {

    // MARK: - Helpers

    private func makeScreen(cols: Int = 10, rows: Int = 3) -> Screen {
        Screen(columns: cols, rows: rows)
    }

    private func writeLine(_ screen: Screen, text: String, attrs: CellAttributes = .default) {
        for ch in text.unicodeScalars {
            screen.write(ch, attributes: attrs)
        }
    }

    // MARK: - Scrollback Accumulation

    @Test func scrollbackEmpty() {
        let screen = makeScreen()
        #expect(screen.scrollbackCount == 0)
        #expect(screen.viewportOffset == 0)
        #expect(!screen.isScrolledUp)
    }

    @Test func scrollbackAccumulatesOnScroll() {
        let screen = makeScreen(cols: 5, rows: 3)
        // Fill 3 rows
        writeLine(screen, text: "AAAAA")
        screen.newline()
        writeLine(screen, text: "BBBBB")
        screen.newline()
        writeLine(screen, text: "CCCCC")
        screen.newline() // This should scroll, pushing "AAAAA" to scrollback
        #expect(screen.scrollbackCount == 1)
        // The scrollback line should contain "AAAAA"
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 4) == "A")
    }

    @Test func scrollbackMaxLimit() {
        let screen = makeScreen(cols: 3, rows: 2)
        // Write more lines than maxScrollback to ensure it caps
        for i in 0..<(screen.maxScrollback + 50) {
            writeLine(screen, text: String(i % 10))
            screen.newline()
        }
        #expect(screen.scrollbackCount == screen.maxScrollback)
    }

    @Test func noScrollbackOnAltScreen() {
        let screen = makeScreen(cols: 5, rows: 2)
        writeLine(screen, text: "AAAAA")
        screen.newline()
        writeLine(screen, text: "BBBBB")
        screen.switchToAltScreen()
        screen.newline() // Scroll on alt screen should NOT save to scrollback
        screen.newline()
        // Only the line that scrolled before alt screen switch should be saved
        let countOnAlt = screen.scrollbackCount
        screen.switchToMainScreen()
        #expect(screen.scrollbackCount == countOnAlt)
    }

    // MARK: - Viewport Scrolling

    @Test func scrollViewportUp() {
        let screen = makeScreen(cols: 3, rows: 2)
        // Generate some scrollback
        for _ in 0..<10 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        #expect(screen.scrollbackCount > 0)
        #expect(screen.viewportOffset == 0)

        screen.scrollViewportUp(lines: 3)
        #expect(screen.viewportOffset == 3)
        #expect(screen.isScrolledUp)
    }

    @Test func scrollViewportUpClampsToMax() {
        let screen = makeScreen(cols: 3, rows: 2)
        for _ in 0..<5 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        let sbCount = screen.scrollbackCount
        screen.scrollViewportUp(lines: sbCount + 100)
        #expect(screen.viewportOffset == sbCount)
    }

    @Test func scrollViewportDown() {
        let screen = makeScreen(cols: 3, rows: 2)
        for _ in 0..<10 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        screen.scrollViewportUp(lines: 5)
        #expect(screen.viewportOffset == 5)
        screen.scrollViewportDown(lines: 2)
        #expect(screen.viewportOffset == 3)
    }

    @Test func scrollViewportDownClampsToZero() {
        let screen = makeScreen(cols: 3, rows: 2)
        screen.scrollViewportUp(lines: 5) // No scrollback, so offset stays 0
        #expect(screen.viewportOffset == 0)

        for _ in 0..<5 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        screen.scrollViewportUp(lines: 3)
        screen.scrollViewportDown(lines: 10)
        #expect(screen.viewportOffset == 0)
    }

    @Test func scrollViewportToBottom() {
        let screen = makeScreen(cols: 3, rows: 2)
        for _ in 0..<10 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        screen.scrollViewportUp(lines: 5)
        screen.scrollViewportToBottom()
        #expect(screen.viewportOffset == 0)
        #expect(!screen.isScrolledUp)
    }

    // MARK: - Text Extraction

    @Test func extractTextSingleLine() {
        let screen = makeScreen(cols: 10, rows: 3)
        writeLine(screen, text: "Hello World") // Will wrap at col 10

        let sel = Selection(
            start: SelectionPoint(line: screen.scrollbackCount, col: 0),
            end: SelectionPoint(line: screen.scrollbackCount, col: 4)
        )
        let text = screen.extractText(from: sel)
        #expect(text == "Hello")
    }

    @Test func extractTextTrimsTrailingSpaces() {
        let screen = makeScreen(cols: 10, rows: 3)
        writeLine(screen, text: "Hi")
        screen.newline()
        writeLine(screen, text: "World")

        let sel = Selection(
            start: SelectionPoint(line: screen.scrollbackCount, col: 0),
            end: SelectionPoint(line: screen.scrollbackCount + 1, col: 4),
            mode: .character
        )
        let text = screen.extractText(from: sel)
        #expect(text == "Hi\nWorld")
    }

    // MARK: - Full Reset

    @Test func fullResetClearsScrollback() {
        let screen = makeScreen(cols: 3, rows: 2)
        for _ in 0..<10 {
            writeLine(screen, text: "ABC")
            screen.newline()
        }
        screen.scrollViewportUp(lines: 3)
        #expect(screen.scrollbackCount > 0)
        #expect(screen.isScrolledUp)

        screen.fullReset()
        #expect(screen.scrollbackCount == 0)
        #expect(screen.viewportOffset == 0)
    }

    // MARK: - Flat Buffer Specifics

    @Test func resizePreservesScrollbackOnColumnChange() {
        let screen = makeScreen(cols: 5, rows: 3)
        for _ in 0..<5 {
            writeLine(screen, text: "ABCDE")
            screen.newline()
        }
        let sbBefore = screen.scrollbackCount
        #expect(sbBefore > 0)

        screen.resize(columns: 8, rows: 3) // Widen
        #expect(screen.scrollbackCount == sbBefore)
        // First scrollback line should still have "ABCDE"
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 4) == "E")
        // Column 5-7 should be empty (space)
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 5) == " ")
    }

    @Test func resizeNarrowReflowsScrollback() {
        let screen = makeScreen(cols: 5, rows: 3)
        for _ in 0..<5 {
            writeLine(screen, text: "ABCDE")
            screen.newline()
        }
        let sbBefore = screen.scrollbackCount
        #expect(sbBefore > 0)

        screen.resize(columns: 3, rows: 3) // Narrow — reflow wraps lines
        // Scrollback count increases because 5-char lines need 2 rows at 3 cols
        #expect(screen.scrollbackCount > sbBefore)
        // First scrollback line should have "ABC" (first row of reflowed "ABCDE")
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == "A")
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 2) == "C")
        // Second scrollback line should have "DE" (second row of reflowed "ABCDE")
        #expect(screen.codepoint(atAbsoluteLine: 1, col: 0) == "D")
        #expect(screen.codepoint(atAbsoluteLine: 1, col: 1) == "E")
    }

    @Test func resizePreservesScrollbackViewportOffset() {
        let screen = makeScreen(cols: 5, rows: 3)
        for _ in 0..<10 {
            writeLine(screen, text: "ABCDE")
            screen.newline()
        }
        screen.scrollViewportUp(lines: 3)
        #expect(screen.viewportOffset == 3)

        screen.resize(columns: 8, rows: 3)
        // Viewport offset should be clamped to valid range after reflow
        #expect(screen.viewportOffset <= screen.scrollbackCount)
    }

    @Test func resizePreservesScrollbackOnRowChange() {
        let screen = makeScreen(cols: 5, rows: 3)
        for _ in 0..<5 {
            writeLine(screen, text: "ABCDE")
            screen.newline()
        }
        let sbBefore = screen.scrollbackCount
        #expect(sbBefore > 0)

        screen.resize(columns: 5, rows: 5) // Row-only change
        #expect(screen.scrollbackCount == sbBefore)
    }

    // MARK: - Viewport Stability on New Output

    @Test func viewportStaysWhenScrolledUp() {
        let screen = makeScreen(cols: 5, rows: 3)
        // Generate scrollback: write 6 lines into a 3-row screen.
        for i in 0..<6 {
            let ch = Unicode.Scalar(UInt32(0x41 + i))! // A, B, C, D, E, F
            for _ in 0..<5 { screen.write(ch, attributes: .default) }
            screen.newline()
        }
        // scrollback should have 4 lines (A, B, C, D), screen has E, F, blank
        #expect(screen.scrollbackCount == 4)

        // Scroll up to view older content
        screen.scrollViewportUp(lines: 2)
        #expect(screen.viewportOffset == 2)

        // Remember what we're looking at: absolute line at top of viewport
        let viewedLine0Before = screen.codepoint(
            atAbsoluteLine: screen.scrollbackCount - screen.viewportOffset, col: 0
        )

        // New output arrives — pushes another line to scrollback
        writeLine(screen, text: "GGGGG")
        screen.newline()
        #expect(screen.scrollbackCount == 5)

        // Viewport offset should have increased to keep the same content in view
        #expect(screen.viewportOffset == 3)

        // The content at the top of the viewport should be the same character
        let viewedLine0After = screen.codepoint(
            atAbsoluteLine: screen.scrollbackCount - screen.viewportOffset, col: 0
        )
        #expect(viewedLine0Before == viewedLine0After)
    }

    @Test func viewportDoesNotChangeWhenAtBottom() {
        let screen = makeScreen(cols: 5, rows: 3)
        for i in 0..<6 {
            let ch = Unicode.Scalar(UInt32(0x41 + i))!
            for _ in 0..<5 { screen.write(ch, attributes: .default) }
            screen.newline()
        }
        #expect(screen.viewportOffset == 0)

        // New output while at bottom — viewport should stay at 0
        writeLine(screen, text: "ZZZZZ")
        screen.newline()
        #expect(screen.viewportOffset == 0)
    }

    @Test func viewportStaysOnRingWrap() {
        let screen = makeScreen(cols: 3, rows: 2)
        // Fill scrollback to max
        for i in 0..<(screen.maxScrollback + 2) {
            let ch = Unicode.Scalar(UInt32(0x41 + (i % 26)))!
            for _ in 0..<3 { screen.write(ch, attributes: .default) }
            screen.newline()
        }
        #expect(screen.scrollbackCount == screen.maxScrollback)

        // Scroll up partway
        screen.scrollViewportUp(lines: 5)
        let offsetBefore = screen.viewportOffset

        // Record content at viewport top
        let viewedBefore = screen.codepoint(
            atAbsoluteLine: screen.scrollbackCount - screen.viewportOffset, col: 0
        )

        // More output causes ring wrap (oldest line discarded)
        writeLine(screen, text: "ZZZ")
        screen.newline()
        #expect(screen.scrollbackCount == screen.maxScrollback)
        #expect(screen.viewportOffset == offsetBefore + 1)

        // Content at viewport top should be the same
        let viewedAfter = screen.codepoint(
            atAbsoluteLine: screen.scrollbackCount - screen.viewportOffset, col: 0
        )
        #expect(viewedBefore == viewedAfter)
    }

    @Test func flatBufferRingWrapAround() {
        let screen = makeScreen(cols: 3, rows: 2)
        // Write more than maxScrollback lines.
        // With 2 rows, the first newline moves cursor to row 1 (no scroll).
        // Subsequent newlines trigger scroll. Total pushes = iterations - 1.
        let extra = 10
        let iterations = screen.maxScrollback + extra
        for i in 0..<iterations {
            let ch = Unicode.Scalar(UInt32(0x41 + (i % 26)))!
            for _ in 0..<3 { screen.write(ch, attributes: .default) }
            screen.newline()
        }
        #expect(screen.scrollbackCount == screen.maxScrollback)
        // Total pushes = iterations - 1; discarded = extra - 1
        // Oldest kept = character at index (extra - 1)
        let oldestIdx = extra - 1
        let expectedOldest = Unicode.Scalar(UInt32(0x41 + (oldestIdx % 26)))!
        #expect(screen.codepoint(atAbsoluteLine: 0, col: 0) == expectedOldest)
        // Newest = character at index (iterations - 2)
        let newestCharIdx = iterations - 2
        let expectedNewest = Unicode.Scalar(UInt32(0x41 + (newestCharIdx % 26)))!
        #expect(screen.codepoint(atAbsoluteLine: screen.maxScrollback - 1, col: 0) == expectedNewest)
    }
}
