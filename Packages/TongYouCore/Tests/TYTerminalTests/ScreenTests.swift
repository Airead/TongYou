import Foundation
import Testing
@testable import TYTerminal

@Suite("Screen tests", .serialized)
struct ScreenTests {

    @Test func fillWithEFillsScreenAndResetsCursor() {
        let screen = Screen(columns: 5, rows: 3)
        screen.write(GraphemeCluster(Character("A")), attributes: .default)
        screen.setCursorPos(row: 1, col: 2)
        let _ = screen.consumeDirtyRegion() // clear initial full rebuild

        screen.fillWithE()

        // All cells should be 'E' with default attributes
        for row in 0..<screen.rows {
            for col in 0..<screen.columns {
                let cell = screen.cell(at: col, row: row)
                #expect(cell.codepoint == "E")
                #expect(cell.attributes == .default)
                #expect(cell.width == .normal)
            }
        }
        // Cursor should be at home position
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
        // Dirty region should be full rebuild
        #expect(screen.consumeDirtyRegion().fullRebuild == true)
    }

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

    // MARK: - Synchronized Update (DECSET 2026)

    @Test func syncedUpdateDefaultsOff() {
        let screen = Screen(columns: 80, rows: 24)
        #expect(screen.syncedUpdateActive == false)
    }

    @Test func syncedUpdateBeginAndEndTogglesFlag() {
        let screen = Screen(columns: 80, rows: 24)
        screen.beginSyncedUpdate()
        #expect(screen.syncedUpdateActive == true)
        screen.endSyncedUpdate()
        #expect(screen.syncedUpdateActive == false)
    }

    @Test func expireSyncedUpdateReturnsFalseWhenInactive() {
        let screen = Screen(columns: 80, rows: 24)
        #expect(screen.expireSyncedUpdateIfStale(timeout: 0.2) == false)
        #expect(screen.syncedUpdateActive == false)
    }

    @Test func expireSyncedUpdateReturnsFalseBeforeTimeout() {
        let screen = Screen(columns: 80, rows: 24)
        let start = Date(timeIntervalSince1970: 1_000)
        screen.beginSyncedUpdate(now: start)
        let before = start.addingTimeInterval(0.1)
        #expect(screen.expireSyncedUpdateIfStale(now: before, timeout: 0.2) == false)
        #expect(screen.syncedUpdateActive == true)
    }

    @Test func expireSyncedUpdateClearsAfterTimeout() {
        let screen = Screen(columns: 80, rows: 24)
        let start = Date(timeIntervalSince1970: 1_000)
        screen.beginSyncedUpdate(now: start)
        let after = start.addingTimeInterval(0.25)
        #expect(screen.expireSyncedUpdateIfStale(now: after, timeout: 0.2) == true)
        #expect(screen.syncedUpdateActive == false)
        // Second call is a no-op.
        #expect(screen.expireSyncedUpdateIfStale(now: after, timeout: 0.2) == false)
    }

    @Test func fullResetClearsSyncedUpdate() {
        let screen = Screen(columns: 80, rows: 24)
        screen.beginSyncedUpdate()
        screen.fullReset()
        #expect(screen.syncedUpdateActive == false)
    }

    // MARK: - Reverse Video (DECSCNM)

    @Test func reverseVideoDefaultsOff() {
        let screen = Screen(columns: 10, rows: 2)
        #expect(screen.reverseVideo == false)
    }

    @Test func reverseVideoSetAndReset() {
        let screen = Screen(columns: 10, rows: 2)
        screen.setReverseVideo(true)
        #expect(screen.reverseVideo == true)
        screen.setReverseVideo(false)
        #expect(screen.reverseVideo == false)
    }

    @Test func reverseVideoMarkedFullOnChange() {
        let screen = Screen(columns: 10, rows: 2)
        let _ = screen.consumeDirtyRegion() // clear initial full rebuild
        screen.setReverseVideo(true)
        #expect(screen.consumeDirtyRegion().fullRebuild == true)
    }

    @Test func fullResetClearsReverseVideo() {
        let screen = Screen(columns: 10, rows: 2)
        screen.setReverseVideo(true)
        screen.fullReset()
        #expect(screen.reverseVideo == false)
    }

    // MARK: - Origin Mode (DECOM)

    @Test func originModeDefaultsOff() {
        let screen = Screen(columns: 10, rows: 5)
        #expect(screen.originMode == false)
    }

    @Test func originModeSetAndReset() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setOriginMode(true)
        #expect(screen.originMode == true)
        screen.setOriginMode(false)
        #expect(screen.originMode == false)
    }

    @Test func setCursorPosWithOriginMode() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setScrollRegion(top: 1, bottom: 3)
        screen.setOriginMode(true)

        // row 0 in origin mode means scrollTop (1)
        screen.setCursorPos(row: 0, col: 0)
        #expect(screen.cursorRow == 1)

        // row 2 means scrollTop + 2 = 3
        screen.setCursorPos(row: 2, col: 5)
        #expect(screen.cursorRow == 3)
        #expect(screen.cursorCol == 5)

        // row beyond scrollBottom is clamped
        screen.setCursorPos(row: 10, col: 0)
        #expect(screen.cursorRow == 3)
    }

    @Test func setCursorPosWithoutOriginMode() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setScrollRegion(top: 1, bottom: 3)
        screen.setOriginMode(false)

        // row 0 means absolute top (0)
        screen.setCursorPos(row: 0, col: 0)
        #expect(screen.cursorRow == 0)

        // row 4 means absolute row 4
        screen.setCursorPos(row: 4, col: 5)
        #expect(screen.cursorRow == 4)
    }

    @Test func setScrollRegionResetsCursorToScrollTopInOriginMode() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setCursorPos(row: 4, col: 5)
        screen.setOriginMode(true)
        screen.setScrollRegion(top: 2, bottom: 4)
        #expect(screen.cursorRow == 2)
        #expect(screen.cursorCol == 0)
    }

    @Test func setScrollRegionResetsCursorToTopWhenOriginModeOff() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setCursorPos(row: 4, col: 5)
        screen.setOriginMode(false)
        screen.setScrollRegion(top: 2, bottom: 4)
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
    }

    @Test func advanceRowRespectsOriginModeBottom() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setScrollRegion(top: 1, bottom: 3)
        screen.setOriginMode(true)
        screen.setCursorPos(row: 2, col: 0) // absolute row 3

        // Trigger advanceRow by writing a character that wraps
        for _ in 0..<10 {
            screen.write(Unicode.Scalar("A"), attributes: .default)
        }
        // After filling the line, advanceRow should scroll, not move past scrollBottom
        #expect(screen.cursorRow == 3)
    }

    @Test func fullResetClearsOriginMode() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setOriginMode(true)
        screen.fullReset()
        #expect(screen.originMode == false)
    }

    // MARK: - Delayed Wrap (DECAWM)

    @Test func pendingWrapDefaultsFalse() {
        let screen = Screen(columns: 5, rows: 3)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapSetsPendingWrapAtLastColumn() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write a single-width character at the last column
        screen.write(GraphemeCluster("A"), attributes: .default)

        // Cursor should stay at last column, pendingWrap should be true
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == true)
        #expect(screen.cell(at: 4, row: 0).codepoint == "A")
    }

    @Test func delayedWrapResolvesOnNextWrite() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // Next write should resolve the wrap first
        screen.write(GraphemeCluster("B"), attributes: .default)

        // Should be at start of next line
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 1)
        #expect(screen.pendingWrap == false)
        #expect(screen.cell(at: 0, row: 1).codepoint == "B")
    }

    @Test func delayedWrapClearedOnCarriageReturn() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // CR should clear pendingWrap and move to column 0 (no wrap executed)
        screen.carriageReturn()

        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapClearedOnLineFeed() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // LF should clear pendingWrap and move down one row (no wrap executed)
        screen.lineFeed()

        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapClearedOnCursorForward() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // cursorForward should clear pendingWrap (no wrap executed, cursor stays at last col)
        screen.cursorForward(1)

        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapClearedOnCursorBackward() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // cursorBackward should clear pendingWrap (no wrap executed)
        screen.cursorBackward(1)

        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 3)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapClearedOnSetCursorPos() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column to trigger delayed wrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // setCursorPos should clear pendingWrap (no wrap executed)
        screen.setCursorPos(row: 2, col: 2)

        #expect(screen.cursorRow == 2)
        #expect(screen.cursorCol == 2)
        #expect(screen.pendingWrap == false)
    }

    @Test func delayedWrapSetsWrappedFlagOnResolve() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        // Row should not be marked wrapped yet
        let beforeFlags = screen.snapshot().lineFlags[0]
        #expect(beforeFlags.wrapped == false)

        // Next write should set wrapped flag
        screen.write(GraphemeCluster("B"), attributes: .default)

        let afterFlags = screen.snapshot().lineFlags[0]
        #expect(afterFlags.wrapped == true)
    }

    @Test func fullResetClearsPendingWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        screen.fullReset()
        #expect(screen.pendingWrap == false)
    }

    @Test func fillWithEClearsPendingWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        screen.fillWithE()
        #expect(screen.pendingWrap == false)
    }

    @Test func wideCharAtLastColumnDoesNotSetPendingWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)

        // Write a wide character at the last column - it should wrap immediately
        screen.write(GraphemeCluster(Character("🇨🇳")), attributes: .default)

        // Should have wrapped, not set pendingWrap
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 2)
        #expect(screen.pendingWrap == false)
    }

    @Test func writeASCIIBatchHandlesDelayedWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 3)

        // Write "AB" - A goes to col 3, B goes to col 4 and sets pendingWrap
        var buffer = PrintBatchBuffer()
        buffer[0] = 0x41 // 'A'
        buffer[1] = 0x42 // 'B'
        screen.writeASCIIBatch(buffer, count: 2, attributes: .default)

        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == true)
        #expect(screen.cell(at: 3, row: 0).codepoint == "A")
        #expect(screen.cell(at: 4, row: 0).codepoint == "B")

        // Next batch write should resolve the wrap
        var buffer2 = PrintBatchBuffer()
        buffer2[0] = 0x43 // 'C'
        screen.writeASCIIBatch(buffer2, count: 1, attributes: .default)

        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 1)
        #expect(screen.pendingWrap == false)
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
    }

    @Test func setPendingWrapUpdatesState() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setPendingWrap(true)
        #expect(screen.pendingWrap == true)
        screen.setPendingWrap(false)
        #expect(screen.pendingWrap == false)
    }

    @Test func autowrapDisabledOverwritesLastColumn() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setAutowrap(false)
        screen.setCursorPos(row: 0, col: 4)

        // Write at last column with autowrap off — should not set pendingWrap
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == false)
        #expect(screen.cell(at: 4, row: 0).codepoint == "A")

        // Next write should overwrite the same cell
        screen.write(GraphemeCluster("B"), attributes: .default)
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == false)
        #expect(screen.cell(at: 4, row: 0).codepoint == "B")
    }

    @Test func autowrapDisabledClearsPendingWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setCursorPos(row: 0, col: 4)
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        screen.setAutowrap(false)
        #expect(screen.pendingWrap == false)
    }

    @Test func autowrapEnabledRespectsPendingWrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setAutowrap(true)
        screen.setCursorPos(row: 0, col: 4)
        screen.write(GraphemeCluster("A"), attributes: .default)
        #expect(screen.pendingWrap == true)

        screen.write(GraphemeCluster("B"), attributes: .default)
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorCol == 1)
    }

    @Test func fullResetRestoresAutowrap() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setAutowrap(false)
        #expect(screen.autowrap == false)
        screen.fullReset()
        #expect(screen.autowrap == true)
    }

    @Test func writeASCIIBatchRespectsAutowrapDisabled() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setAutowrap(false)
        screen.setCursorPos(row: 0, col: 3)

        var buffer = PrintBatchBuffer()
        buffer[0] = 0x41 // 'A'
        buffer[1] = 0x42 // 'B'
        buffer[2] = 0x43 // 'C'
        screen.writeASCIIBatch(buffer, count: 3, attributes: .default)

        // Should overwrite last column three times, staying at col 4
        #expect(screen.cursorCol == 4)
        #expect(screen.pendingWrap == false)
        #expect(screen.cell(at: 4, row: 0).codepoint == "C")
    }

    // MARK: - Insert Mode (IRM)

    @Test func insertModeInitiallyDisabled() {
        let screen = Screen(columns: 10, rows: 3)
        #expect(screen.insertMode == false)
    }

    @Test func setInsertModeUpdatesState() {
        let screen = Screen(columns: 10, rows: 3)
        screen.setInsertMode(true)
        #expect(screen.insertMode == true)
        screen.setInsertMode(false)
        #expect(screen.insertMode == false)
    }

    @Test func insertModeShiftsCharactersRight() {
        let screen = Screen(columns: 10, rows: 3)
        screen.setInsertMode(true)

        // Write "ABC"
        screen.write(GraphemeCluster("A"), attributes: .default)
        screen.write(GraphemeCluster("B"), attributes: .default)
        screen.write(GraphemeCluster("C"), attributes: .default)

        // Move cursor back to column 1 and insert "X"
        screen.setCursorCol(1)
        screen.write(GraphemeCluster("X"), attributes: .default)

        // Result should be "AXBC"
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "X")
        #expect(screen.cell(at: 2, row: 0).codepoint == "B")
        #expect(screen.cell(at: 3, row: 0).codepoint == "C")
        #expect(screen.cursorCol == 2)
    }

    @Test func insertModeShiftsAtEndOfLine() {
        let screen = Screen(columns: 5, rows: 3)
        screen.setInsertMode(true)

        // Write "AB" at positions 0 and 1
        screen.write(GraphemeCluster("A"), attributes: .default)
        screen.write(GraphemeCluster("B"), attributes: .default)

        // Move to end of line and insert "X"
        screen.setCursorCol(4)
        screen.write(GraphemeCluster("X"), attributes: .default)

        // X should go at position 4, previous content shifts left (truncated)
        #expect(screen.cell(at: 4, row: 0).codepoint == "X")
    }

    @Test func insertModeWithWideCharacter() {
        let screen = Screen(columns: 10, rows: 3)
        screen.setInsertMode(true)

        // Write "A" then emoji
        screen.write(GraphemeCluster("A"), attributes: .default)
        screen.setCursorCol(0)

        // Insert wide character (emoji)
        screen.write(GraphemeCluster("😀"), attributes: .default)

        // Emoji takes 2 cells, A should be shifted to position 2
        #expect(screen.cell(at: 0, row: 0).codepoint == "😀")
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 2, row: 0).codepoint == "A")
    }

    @Test func insertModeDisabledWritesNormally() {
        let screen = Screen(columns: 10, rows: 3)
        screen.setInsertMode(false) // explicitly disable

        // Write "AB"
        screen.write(GraphemeCluster("A"), attributes: .default)
        screen.write(GraphemeCluster("B"), attributes: .default)

        // Move cursor back to column 0 and write "X"
        screen.setCursorCol(0)
        screen.write(GraphemeCluster("X"), attributes: .default)

        // X should overwrite A, not shift it
        #expect(screen.cell(at: 0, row: 0).codepoint == "X")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
    }
}
