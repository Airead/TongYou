import Testing
import TYTerminal
@testable import TongYou

@Suite struct SearchTests {

    // MARK: - SearchResult Tests

    @Test func emptyResult() {
        let result = SearchResult.empty
        #expect(result.isEmpty)
        #expect(result.count == 0)
        #expect(result.focusedMatch == nil)
    }

    @Test func focusNext_wrapsAround() {
        var result = SearchResult(
            matches: [
                SearchMatch(line: 0, startCol: 0, endCol: 2),
                SearchMatch(line: 1, startCol: 0, endCol: 2),
                SearchMatch(line: 2, startCol: 0, endCol: 2),
            ],
            query: "abc",
            focusedIndex: 2
        )
        result.focusNext()
        #expect(result.focusedIndex == 0)
    }

    @Test func focusPrevious_wrapsAround() {
        var result = SearchResult(
            matches: [
                SearchMatch(line: 0, startCol: 0, endCol: 2),
                SearchMatch(line: 1, startCol: 0, endCol: 2),
            ],
            query: "abc",
            focusedIndex: 0
        )
        result.focusPrevious()
        #expect(result.focusedIndex == 1)
    }

    @Test func focusNearest() {
        var result = SearchResult(
            matches: [
                SearchMatch(line: 5, startCol: 0, endCol: 2),
                SearchMatch(line: 50, startCol: 0, endCol: 2),
                SearchMatch(line: 100, startCol: 0, endCol: 2),
            ],
            query: "abc",
            focusedIndex: nil
        )
        result.focusNearest(toAbsoluteLine: 48)
        #expect(result.focusedIndex == 1)
    }

    @Test func focusNext_fromNil() {
        var result = SearchResult(
            matches: [SearchMatch(line: 0, startCol: 0, endCol: 2)],
            query: "abc",
            focusedIndex: nil
        )
        result.focusNext()
        #expect(result.focusedIndex == 0)
    }

    @Test func focusPrevious_fromNil() {
        var result = SearchResult(
            matches: [
                SearchMatch(line: 0, startCol: 0, endCol: 2),
                SearchMatch(line: 1, startCol: 0, endCol: 2),
            ],
            query: "abc",
            focusedIndex: nil
        )
        result.focusPrevious()
        #expect(result.focusedIndex == 1)
    }

    // MARK: - Screen.search Tests

    @Test func searchFindsSimpleMatch() {
        let screen = Screen(columns: 10, rows: 3)
        writeString(screen, "hello     ", row: 0)
        writeString(screen, "world     ", row: 1)

        let matches = screen.search(query: "hello")
        #expect(matches.count == 1)
        #expect(matches[0].line == 0)
        #expect(matches[0].startCol == 0)
        #expect(matches[0].endCol == 4)
    }

    @Test func searchCaseInsensitive() {
        let screen = Screen(columns: 10, rows: 2)
        writeString(screen, "Hello     ", row: 0)
        writeString(screen, "HELLO     ", row: 1)

        let matches = screen.search(query: "hello")
        #expect(matches.count == 2)
    }

    @Test func searchMultipleMatchesPerLine() {
        let screen = Screen(columns: 20, rows: 1)
        writeString(screen, "abcabcabc           ", row: 0)

        let matches = screen.search(query: "abc")
        #expect(matches.count == 3)
        #expect(matches[0].startCol == 0)
        #expect(matches[1].startCol == 3)
        #expect(matches[2].startCol == 6)
    }

    @Test func searchNoMatch() {
        let screen = Screen(columns: 10, rows: 2)
        writeString(screen, "hello     ", row: 0)

        let matches = screen.search(query: "xyz")
        #expect(matches.isEmpty)
    }

    @Test func searchEmptyQuery() {
        let screen = Screen(columns: 10, rows: 2)
        writeString(screen, "hello     ", row: 0)

        let matches = screen.search(query: "")
        #expect(matches.isEmpty)
    }

    @Test func searchMultipleLines() {
        let screen = Screen(columns: 10, rows: 3)
        writeString(screen, "abc  def  ", row: 0)
        writeString(screen, "  abc     ", row: 1)
        writeString(screen, "xyzabc    ", row: 2)

        let matches = screen.search(query: "abc")
        #expect(matches.count == 3)
        #expect(matches[0].line == 0)
        #expect(matches[0].startCol == 0)
        #expect(matches[1].line == 1)
        #expect(matches[1].startCol == 2)
        #expect(matches[2].line == 2)
        #expect(matches[2].startCol == 3)
    }

    @Test func searchInScrollback() {
        let screen = Screen(columns: 5, rows: 2, maxScrollback: 100)
        // Fill screen and push content into scrollback.
        // Row 0 and 1 are the screen; writing 4 rows pushes 2 into scrollback.
        for ch in ["A", "B", "C", "D"] {
            for scalar in ch.unicodeScalars {
                for _ in 0..<5 {
                    screen.write(scalar)
                }
            }
        }
        // scrollback should have lines with "AAAAA" and "BBBBB"
        // screen should have "CCCCC" and "DDDDD"
        let matches = screen.search(query: "AAA")
        #expect(matches.count == 1)
        #expect(matches[0].startCol == 0)
        #expect(matches[0].endCol == 2)
    }

    // MARK: - Helpers

    /// Write a string at a specific row by setting cursor position.
    private func writeString(_ screen: Screen, _ text: String, row: Int) {
        screen.setCursorPos(row: row, col: 0)
        for scalar in text.unicodeScalars {
            screen.write(scalar)
        }
    }
}
