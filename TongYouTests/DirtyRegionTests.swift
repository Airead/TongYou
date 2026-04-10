import Testing
@testable import TongYou

@Suite struct DirtyRegionTests {

    // MARK: - DirtyRegion struct tests

    @Test func cleanIsNotDirty() {
        let region = DirtyRegion.clean
        #expect(!region.isDirty)
        #expect(region.lineRange == nil)
        #expect(!region.fullRebuild)
    }

    @Test func fullIsDirty() {
        let region = DirtyRegion.full
        #expect(region.isDirty)
        #expect(region.fullRebuild)
    }

    @Test func markSingleLine() {
        var region = DirtyRegion.clean
        region.markLine(5)
        #expect(region.isDirty)
        #expect(region.lineRange == 5..<6)
        #expect(!region.fullRebuild)
    }

    @Test func markMultipleLines() {
        var region = DirtyRegion.clean
        region.markLine(3)
        region.markLine(7)
        #expect(region.lineRange == 3..<8)
    }

    @Test func markRange() {
        var region = DirtyRegion.clean
        region.markRange(2..<5)
        #expect(region.lineRange == 2..<5)
    }

    @Test func markRangeExpandsExisting() {
        var region = DirtyRegion.clean
        region.markRange(2..<5)
        region.markRange(4..<8)
        #expect(region.lineRange == 2..<8)
    }

    @Test func markEmptyRangeIsNoop() {
        var region = DirtyRegion.clean
        region.markRange(3..<3)
        #expect(!region.isDirty)
    }

    @Test func markFullClearsLineRange() {
        var region = DirtyRegion.clean
        region.markLine(5)
        region.markFull()
        #expect(region.fullRebuild)
        #expect(region.lineRange == nil)
    }

    @Test func markLineAfterFullIsNoop() {
        var region = DirtyRegion.full
        region.markLine(3)
        #expect(region.fullRebuild)
        #expect(region.lineRange == nil)
    }

    @Test func mergeCleanIntoClean() {
        var a = DirtyRegion.clean
        a.merge(.clean)
        #expect(!a.isDirty)
    }

    @Test func mergePartialIntoClean() {
        var a = DirtyRegion.clean
        var b = DirtyRegion.clean
        b.markLine(3)
        a.merge(b)
        #expect(a.lineRange == 3..<4)
    }

    @Test func mergeFullIntoPartial() {
        var a = DirtyRegion.clean
        a.markLine(3)
        a.merge(.full)
        #expect(a.fullRebuild)
    }

    @Test func mergeTwoPartials() {
        var a = DirtyRegion.clean
        a.markRange(1..<3)
        var b = DirtyRegion.clean
        b.markRange(5..<8)
        a.merge(b)
        #expect(a.lineRange == 1..<8)
    }

    // MARK: - Screen dirty tracking tests

    @Test func initialScreenIsFull() {
        let screen = Screen(columns: 80, rows: 24)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func consumeResets() {
        let screen = Screen(columns: 80, rows: 24)
        let region = screen.consumeDirtyRegion()
        #expect(region.fullRebuild)
        #expect(!screen.dirtyRegion.isDirty)
    }

    @Test func writeMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.write("A")
        #expect(screen.dirtyRegion.lineRange == 0..<1)
        #expect(!screen.dirtyRegion.fullRebuild)
    }

    @Test func writeOnMultipleRowsExpandsRange() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 2, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.write("A")
        screen.setCursorPos(row: 5, col: 0)
        screen.write("B")
        #expect(screen.dirtyRegion.lineRange == 2..<6)
    }

    @Test func cursorMoveMarksOldAndNewRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 3, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.cursorUp(2)
        #expect(screen.dirtyRegion.lineRange == 1..<4)
    }

    @Test func eraseLineMarksSingleRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 5, col: 10)
        _ = screen.consumeDirtyRegion()
        screen.eraseLine(mode: 2)
        #expect(screen.dirtyRegion.lineRange == 5..<6)
    }

    @Test func eraseDisplayBelowMarksRange() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 10, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.eraseDisplay(mode: 0)
        #expect(screen.dirtyRegion.lineRange == 10..<24)
    }

    @Test func eraseDisplayAllMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.eraseDisplay(mode: 2)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func scrollUpMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.scrollUp(count: 1)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func scrollDownMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.scrollDown(count: 1)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func resizeMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.resize(columns: 100, rows: 30)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func clearMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.clear()
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func insertCharactersMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 3, col: 5)
        _ = screen.consumeDirtyRegion()
        screen.insertCharacters(count: 2)
        #expect(screen.dirtyRegion.lineRange == 3..<4)
    }

    @Test func deleteCharactersMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 4, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.deleteCharacters(count: 3)
        #expect(screen.dirtyRegion.lineRange == 4..<5)
    }

    @Test func insertLinesMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 5, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.insertLines(count: 1)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func deleteLinesMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 5, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.deleteLines(count: 1)
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func switchToAltScreenMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.switchToAltScreen()
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func switchToMainScreenMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        screen.switchToAltScreen()
        _ = screen.consumeDirtyRegion()
        screen.switchToMainScreen()
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func fullResetMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.fullReset()
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func snapshotCarriesDirtyRegion() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.write("X")
        let snapshot = screen.snapshot()
        #expect(snapshot.dirtyRegion.lineRange == 0..<1)
        #expect(!snapshot.dirtyRegion.fullRebuild)
        // After snapshot, screen dirty region should be reset
        #expect(!screen.dirtyRegion.isDirty)
    }

    @Test func lineFeedMarksBothRows() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 5, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.lineFeed()
        // lineFeed marks old row (5) and new row (6)
        #expect(screen.dirtyRegion.lineRange == 5..<7)
    }

    @Test func lineFeedAtBottomMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 23, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.lineFeed()
        // At scroll bottom, triggers scrollRegionUp → fullRebuild
        #expect(screen.dirtyRegion.fullRebuild)
    }

    @Test func setCursorVisibleMarksCursorRow() {
        let screen = Screen(columns: 80, rows: 24)
        screen.setCursorPos(row: 3, col: 0)
        _ = screen.consumeDirtyRegion()
        screen.setCursorVisible(false)
        #expect(screen.dirtyRegion.lineRange == 3..<4)
    }

    @Test func eraseDisplayAboveMarksRange() {
        let screen = Screen(columns: 80, rows: 24)
        _ = screen.consumeDirtyRegion()
        screen.setCursorPos(row: 10, col: 5)
        _ = screen.consumeDirtyRegion()
        screen.eraseDisplay(mode: 1)
        #expect(screen.dirtyRegion.lineRange == 0..<11)
    }

    @Test func viewportScrollMarksFull() {
        let screen = Screen(columns: 80, rows: 24)
        // Need scrollback lines first
        for _ in 0..<30 {
            screen.newline()
        }
        _ = screen.consumeDirtyRegion()
        screen.scrollViewportUp(lines: 3)
        #expect(screen.dirtyRegion.fullRebuild)
    }
}
