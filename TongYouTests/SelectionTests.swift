import Testing
@testable import TongYou

struct SelectionTests {

    @Test func containsSingleLine() {
        let sel = Selection(
            start: SelectionPoint(line: 5, col: 3),
            end: SelectionPoint(line: 5, col: 10)
        )
        #expect(sel.contains(line: 5, col: 3))
        #expect(sel.contains(line: 5, col: 7))
        #expect(sel.contains(line: 5, col: 10))
        #expect(!sel.contains(line: 5, col: 2))
        #expect(!sel.contains(line: 5, col: 11))
        #expect(!sel.contains(line: 4, col: 5))
        #expect(!sel.contains(line: 6, col: 5))
    }

    @Test func containsMultiLine() {
        let sel = Selection(
            start: SelectionPoint(line: 2, col: 5),
            end: SelectionPoint(line: 4, col: 10)
        )
        // First line: from col 5 onwards
        #expect(!sel.contains(line: 2, col: 4))
        #expect(sel.contains(line: 2, col: 5))
        #expect(sel.contains(line: 2, col: 80))
        // Middle line: fully selected
        #expect(sel.contains(line: 3, col: 0))
        #expect(sel.contains(line: 3, col: 80))
        // Last line: up to col 10
        #expect(sel.contains(line: 4, col: 0))
        #expect(sel.contains(line: 4, col: 10))
        #expect(!sel.contains(line: 4, col: 11))
    }

    @Test func containsReversedSelection() {
        // End before start (user dragged upward)
        let sel = Selection(
            start: SelectionPoint(line: 5, col: 10),
            end: SelectionPoint(line: 3, col: 2)
        )
        #expect(sel.contains(line: 3, col: 2))
        #expect(sel.contains(line: 4, col: 5))
        #expect(sel.contains(line: 5, col: 10))
        #expect(!sel.contains(line: 5, col: 11))
        #expect(!sel.contains(line: 3, col: 1))
    }

    @Test func orderedNormalization() {
        let sel = Selection(
            start: SelectionPoint(line: 10, col: 5),
            end: SelectionPoint(line: 3, col: 8)
        )
        let (s, e) = sel.ordered
        #expect(s.line == 3)
        #expect(s.col == 8)
        #expect(e.line == 10)
        #expect(e.col == 5)
    }

    @Test func orderedAlreadyOrdered() {
        let sel = Selection(
            start: SelectionPoint(line: 3, col: 2),
            end: SelectionPoint(line: 3, col: 8)
        )
        let (s, e) = sel.ordered
        #expect(s.col == 2)
        #expect(e.col == 8)
    }
}
