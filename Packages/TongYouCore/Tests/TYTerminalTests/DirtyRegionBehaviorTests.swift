import Foundation
import Testing
@testable import TYTerminal

@Suite("DirtyRegion behavior tests")
struct DirtyRegionBehaviorTests {

    // MARK: - Helpers

    private func consume(_ screen: Screen) -> DirtyRegion {
        screen.consumeDirtyRegion()
    }

    private func writeString(_ screen: Screen, _ text: String) {
        for scalar in text.unicodeScalars {
            screen.write(scalar)
        }
    }

    // MARK: - Basic writing

    @Test func writeSingleCharMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        writeString(screen, "a")
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [0])
    }

    @Test func writeMultipleCharsOnSameLineMarksSingleRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        writeString(screen, "abc")
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [0])
    }

    // MARK: - Cursor movement

    @Test func writeAfterCursorJumpMarksTargetRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.setCursorPos(row: 5, col: 0)
        _ = consume(screen)

        writeString(screen, "x")
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [5])
    }

    @Test func cursorUpMarksOldAndNewRow() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 10)
        _ = consume(screen)

        screen.cursorUp(2)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows.sorted() == [3, 5])
    }

    // MARK: - Discontiguous lines

    @Test func discontiguousWritesPreserveIndividualRows() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.setCursorPos(row: 10, col: 0)
        writeString(screen, "A")
        screen.setCursorPos(row: 12, col: 0)
        writeString(screen, "B")
        screen.setCursorPos(row: 8, col: 0)
        writeString(screen, "C")

        let region = consume(screen)

        #expect(!region.fullRebuild)
        // Row 0 is dirty because moveCursorRow marks the old cursor position (0,0).
        // Must NOT be merged into a single range (old behavior would yield 0..<13)
        #expect(region.dirtyRows == [0, 8, 10, 12])
    }

    // MARK: - Scrolling

    @Test func lineFeedAtBottomUsesScrollDelta() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 23, col: 0)
        _ = consume(screen)

        screen.lineFeed()
        let region = consume(screen)

        // Full-screen scroll now uses scrollDelta instead of fullRebuild.
        #expect(!region.fullRebuild)
        #expect(region.scrollDelta == 1)
        // Only the newly revealed bottom row (and cursor row) should be dirty.
        #expect(region.isDirty(row: 23))
        #expect(!region.isDirty(row: 0))
    }

    @Test func multipleLineFeedsAccumulateScrollDelta() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 23, col: 0)
        _ = consume(screen)

        screen.lineFeed()
        screen.lineFeed()
        screen.lineFeed()
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.scrollDelta == 3)
    }

    @Test func scrollDeltaOverflowFallsBackToFullRebuild() {
        let screen = Screen(columns: 80, rows: 4)
        screen.setCursorPos(row: 3, col: 0)
        _ = consume(screen)

        // Scroll more than the total row count.
        for _ in 0..<5 {
            screen.lineFeed()
        }
        let region = consume(screen)

        #expect(region.fullRebuild)
        #expect(region.scrollDelta == 0)
    }

    @Test func explicitScrollUpMarksAllRowsDirty() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.scrollUp(count: 1)
        let region = consume(screen)

        // scrollUp uses markRange (not markFull) since df71289.
        #expect(!region.fullRebuild)
        #expect(region.lineRange == 0..<24)
    }

    @Test func explicitScrollDownMarksAllRowsDirty() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.scrollDown(count: 1)
        let region = consume(screen)

        // scrollDown uses markRange (not markFull) since df71289.
        #expect(!region.fullRebuild)
        #expect(region.lineRange == 0..<24)
    }

    // MARK: - Erasing

    @Test func eraseDisplayBelowMarksContiguousRange() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 10)
        _ = consume(screen)

        screen.eraseDisplay(mode: 0)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.lineRange == 5..<24)
    }

    @Test func eraseDisplayAboveMarksContiguousRange() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 10)
        _ = consume(screen)

        screen.eraseDisplay(mode: 1)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.lineRange == 0..<6)
    }

    @Test func eraseDisplayAllMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.eraseDisplay(mode: 2)
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    @Test func eraseLineMarksSingleRow() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        _ = consume(screen)

        screen.eraseLine(mode: 2)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [5])
    }

    // MARK: - Insert / Delete

    @Test func insertCharactersMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 3, col: 5)
        _ = consume(screen)

        screen.insertCharacters(count: 2)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [3])
    }

    @Test func deleteCharactersMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 3, col: 5)
        _ = consume(screen)

        screen.deleteCharacters(count: 3)
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [3])
    }

    @Test func insertLinesMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        _ = consume(screen)

        screen.insertLines(count: 1)
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    @Test func deleteLinesMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        _ = consume(screen)

        screen.deleteLines(count: 1)
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    // MARK: - Screen reset

    @Test func clearMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.clear()
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    @Test func fullResetMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.fullReset()
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    // MARK: - Resize

    @Test func resizeMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        screen.resize(columns: 100, rows: 30)
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    // MARK: - Viewport scroll

    @Test func scrollViewportUpMarksFullRebuild() {
        let screen = Screen(columns: 80, rows: 24)
        for _ in 0..<30 {
            screen.newline()
        }
        _ = consume(screen)

        screen.scrollViewportUp(lines: 3)
        let region = consume(screen)

        #expect(region.fullRebuild)
    }

    // MARK: - Batch write

    @Test func batchWriteMarksSingleRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = consume(screen)

        for scalar in "hello world".unicodeScalars {
            screen.write(scalar)
        }
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows == [0])
    }

    // MARK: - Line feed (non-scroll)

    @Test func lineFeedNonScrollMarksBothRows() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        _ = consume(screen)

        screen.lineFeed()
        let region = consume(screen)

        #expect(!region.fullRebuild)
        #expect(region.dirtyRows.sorted() == [5, 6])
    }
}
