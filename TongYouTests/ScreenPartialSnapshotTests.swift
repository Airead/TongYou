import Foundation
import Testing
@testable import TYTerminal

@Suite("Screen partial snapshot tests")
struct ScreenPartialSnapshotTests {

    @Test func partialSnapshotOnlyCopiesDirtyRows() {
        let screen = Screen(columns: 10, rows: 5)
        _ = screen.consumeDirtyRegion()

        // Avoid cursor-movement dirty marks by positioning once and consuming.
        screen.setCursorPos(row: 1, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.write("A")

        screen.setCursorPos(row: 3, col: 0)
        screen.write("B")

        let snapshot = screen.snapshot(allowPartial: true)

        #expect(snapshot.isPartial == true)
        #expect(snapshot.dirtyRows.sorted() == [1, 3])
        #expect(snapshot.cells.isEmpty)
        #expect(snapshot.partialRows.count == 2)

        let row1 = snapshot.partialRows.first { $0.row == 1 }
        let row3 = snapshot.partialRows.first { $0.row == 3 }
        #expect(row1 != nil)
        #expect(row3 != nil)
        #expect(row1?.cells.count == 10)
        #expect(row3?.cells.count == 10)
        #expect(row1?.cells[0].codepoint == "A")
        #expect(row3?.cells[0].codepoint == "B")
    }

    @Test func scrollUpProducesPartialSnapshotWithAllRows() {
        let screen = Screen(columns: 10, rows: 5)
        _ = screen.consumeDirtyRegion()
        screen.write("A")
        screen.scrollUp(count: 1)

        let snapshot = screen.snapshot(allowPartial: true)

        #expect(snapshot.isPartial)
        #expect(snapshot.cells.isEmpty)
        #expect(snapshot.partialRows.count == 5)
        #expect(snapshot.dirtyRegion.dirtyRows.sorted() == [0, 1, 2, 3, 4])
    }

    @Test func viewportOffsetProducesNonPartialSnapshot() {
        let screen = Screen(columns: 10, rows: 5)
        _ = screen.consumeDirtyRegion()
        for _ in 0..<10 {
            screen.newline()
        }
        _ = screen.consumeDirtyRegion()
        screen.scrollViewportUp(lines: 2)

        let snapshot = screen.snapshot(allowPartial: true)

        #expect(!snapshot.isPartial)
        #expect(snapshot.cells.count == 50)
    }

    @Test func cleanScreenProducesNonPartialSnapshot() {
        let screen = Screen(columns: 10, rows: 5)
        _ = screen.consumeDirtyRegion()

        let snapshot = screen.snapshot(allowPartial: true)

        #expect(!snapshot.isPartial)
        #expect(snapshot.cells.count == 50)
    }

    @Test func defaultSnapshotIsNonPartial() {
        let screen = Screen(columns: 10, rows: 5)
        screen.write("X")

        let snapshot = screen.snapshot()

        #expect(!snapshot.isPartial)
        #expect(snapshot.cells.count == 50)
    }

    @Test func partialSnapshotPreservesCursorAndViewportMetadata() {
        let screen = Screen(columns: 10, rows: 5)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 2, col: 4)
        screen.write("Z")

        let snapshot = screen.snapshot(allowPartial: true)

        #expect(snapshot.isPartial)
        #expect(snapshot.columns == 10)
        #expect(snapshot.rows == 5)
        #expect(snapshot.cursorRow == 2)
        #expect(snapshot.cursorCol == 5)
        #expect(snapshot.viewportOffset == 0)
    }
}
