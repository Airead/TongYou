import Foundation
import Testing
@testable import TYTerminal

/// Feed raw bytes through VTParser → StreamHandler → Screen, return screen.
private func processVTScreen(_ s: String, columns: Int = 80, rows: Int = 24) -> Screen {
    let screen = Screen(columns: columns, rows: rows)
    var handler = StreamHandler(screen: screen)
    var parser = VTParser()
    let bytes = Array(s.utf8)
    bytes.withUnsafeBufferPointer { ptr in
        parser.feed(ptr) { action in
            handler.handle(action)
        }
    }
    handler.flush()
    return screen
}

@Suite("StreamHandler grapheme cluster tests", .serialized)
struct StreamHandlerGraphemeClusterTests {

    @Test func zwjSequenceRendersAsOneCell() {
        let screen = processVTScreen("👨‍👩‍👧‍👦", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 7)
        #expect(screen.cursorCol == 2)
    }

    @Test func skinToneModifierRendersAsOneCell() {
        let screen = processVTScreen("👋🏻", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 2)
        #expect(screen.cursorCol == 2)
    }

    @Test func flagEmojiRendersAsOneCell() {
        let screen = processVTScreen("🇨🇳", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 2)
        #expect(screen.cursorCol == 2)
    }

    @Test func mixedAsciiAndEmoji() {
        let screen = processVTScreen("A👨‍👩‍👧‍👦B", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 0, row: 0).width == .normal)
        #expect(screen.cell(at: 1, row: 0).content.scalarCount == 7)
        #expect(screen.cell(at: 1, row: 0).width == .wide)
        #expect(screen.cell(at: 3, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 3, row: 0).width == .normal)
        #expect(screen.cursorCol == 4)
    }

    @Test func graphemeClusterFlushedBeforeCursorMove() {
        let screen = processVTScreen("A\u{1B}[H", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
    }

    @Test func simpleAsciiStillWorks() {
        let screen = processVTScreen("Hello", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "H")
        #expect(screen.cell(at: 4, row: 0).codepoint == "o")
        #expect(screen.cursorCol == 5)
    }
}

@Suite("StreamHandler ACS tests", .serialized)
struct StreamHandlerACSTests {

    @Test func acsG0BoxDrawing() {
        let screen = processVTScreen("\u{1B}(0q")
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 0, row: 0).content.firstScalar == Unicode.Scalar(0x2500)) // ─
    }

    @Test func acsG1WithShiftOut() {
        let screen = processVTScreen("\u{1B})0\u{0E}x\u{0F}A")
        #expect(screen.cell(at: 0, row: 0).content.firstScalar == Unicode.Scalar(0x2502)) // │ (SO -> G1)
        #expect(screen.cell(at: 1, row: 0).content.firstScalar == Unicode.Scalar("A"))     // SI -> G0 ascii
    }

    @Test func acsExitWithAscii() {
        let screen = processVTScreen("\u{1B}(0q\u{1B}(BA")
        #expect(screen.cell(at: 0, row: 0).content.firstScalar == Unicode.Scalar(0x2500)) // ─
        #expect(screen.cell(at: 1, row: 0).content.firstScalar == Unicode.Scalar("A"))     // A
    }

    @Test func acsCursorSaveRestore() {
        // Save cursor at (1,0) in ACS mode, switch to ASCII, write B, restore, write q in ACS.
        let screen = processVTScreen("\u{1B}(0A\u{1B}7\u{1B}(BB\u{1B}8q")
        #expect(screen.cell(at: 0, row: 0).content.firstScalar == Unicode.Scalar("A"))     // A was plain ASCII even in ACS
        #expect(screen.cell(at: 1, row: 0).content.firstScalar == Unicode.Scalar(0x2500)) // q restored ACS -> ─
    }
}

@Suite("StreamHandler synchronized output (mode 2026) tests", .serialized)
struct StreamHandlerSyncedUpdateTests {

    /// Feed bytes through parser + handler and return the owning screen plus
    /// any `onWriteBack` bytes captured (DECRQM replies, DSR, etc.).
    private func drive(_ s: String) -> (Screen, [UInt8]) {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var written: [UInt8] = []
        handler.onWriteBack = { written.append(contentsOf: $0) }
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        return (screen, written)
    }

    @Test func mode2026BeginAndEndTogglesSyncFlag() {
        let (screenBegin, _) = drive("\u{1B}[?2026h")
        #expect(screenBegin.syncedUpdateActive == true)

        let (screenEnd, _) = drive("\u{1B}[?2026h\u{1B}[?2026l")
        #expect(screenEnd.syncedUpdateActive == false)
    }

    @Test func decrqm2026ReportsResetWhenInactive() {
        let (_, written) = drive("\u{1B}[?2026$p")
        let reply = String(bytes: written, encoding: .ascii)
        #expect(reply == "\u{1B}[?2026;2$y")
    }

    @Test func decrqm2026ReportsSetWhenActive() {
        let (_, written) = drive("\u{1B}[?2026h\u{1B}[?2026$p")
        let reply = String(bytes: written, encoding: .ascii)
        #expect(reply == "\u{1B}[?2026;1$y")
    }

    @Test func decrqmUnrelatedModeIsSilentlyDropped() {
        // Phase 2 deliberately answers only mode 2026 — others should not
        // trigger any write-back.
        let (_, written) = drive("\u{1B}[?1004$p")
        #expect(written.isEmpty)
    }
}

@Suite("StreamHandler focus reporting (mode 1004) tests", .serialized)
struct StreamHandlerFocusReportingTests {

    /// Drive a sequence of bytes through the handler, recording every
    /// `onFocusReportingChanged` notification in order.
    private func run(_ s: String) -> [Bool] {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var events: [Bool] = []
        handler.onFocusReportingChanged = { events.append($0) }
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        return events
    }

    @Test func focusReportingInitiallyOff() {
        let screen = Screen(columns: 10, rows: 2)
        let handler = StreamHandler(screen: screen)
        #expect(handler.modes.isSet(.focusEvents) == false)
    }

    @Test func focusReportingModeToggles() {
        #expect(run("\u{1B}[?1004h") == [true])
        #expect(run("\u{1B}[?1004l") == [false])
        #expect(run("\u{1B}[?1004h\u{1B}[?1004l") == [true, false])
    }
}

@Suite("StreamHandler unhandled sequence tests", .serialized)
struct StreamHandlerUnhandledSequenceTests {

    /// Drive a sequence of bytes through the handler, recording every
    /// `onUnhandledSequence` notification in order.
    private func run(_ s: String) -> [String] {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var events: [String] = []
        handler.onUnhandledSequence = { events.append($0) }
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        return events
    }

    @Test func unsupportedModeTriggersCallback() {
        // Mode 1005 (UTF-8 mouse) is not supported
        #expect(run("\u{1B}[?1005h") == ["DECSET/DECRST mode 1005 not implemented"])
    }

    @Test func supportedModeDoesNotTriggerCallback() {
        // Mode 1004 (focus events) is supported
        #expect(run("\u{1B}[?1004h").isEmpty)
    }

    @Test func multipleUnsupportedModesAreReported() {
        #expect(run("\u{1B}[?1005h\u{1B}[?1006h\u{1B}[?1007h") == ["DECSET/DECRST mode 1005 not implemented", "DECSET/DECRST mode 1007 not implemented"])
        // 1006 is supported (mouse format), so only 1005 and 1007 are reported
    }
}
