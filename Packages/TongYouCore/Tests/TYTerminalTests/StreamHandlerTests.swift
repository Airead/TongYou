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

    @Test func cursorKeysAndBracketedPasteModesDoNotLog() {
        // These are passive modes (consumers read the bitfield directly).
        // They should not produce unhandled sequence callbacks.
        #expect(run("\u{1B}[?1h").isEmpty)   // cursorKeys
        #expect(run("\u{1B}[?1l").isEmpty)   // cursorKeys reset
        #expect(run("\u{1B}[?2004h").isEmpty) // bracketedPaste
        #expect(run("\u{1B}[?2004l").isEmpty) // bracketedPaste reset
    }

    @Test func vttestModesThreeToSixDoNotLog() {
        // DECCOLM (3), DECSCLM (4), DECSCNM (5), DECOM (6) are recognized
        // but currently have no side effects in StreamHandler.
        #expect(run("\u{1B}[?3h").isEmpty)  // DECCOLM
        #expect(run("\u{1B}[?3l").isEmpty)  // DECCOLM reset
        #expect(run("\u{1B}[?4h").isEmpty)  // DECSCLM
        #expect(run("\u{1B}[?4l").isEmpty)  // DECSCLM reset
        #expect(run("\u{1B}[?5h").isEmpty)  // DECSCNM
        #expect(run("\u{1B}[?5l").isEmpty)  // DECSCNM reset
        #expect(run("\u{1B}[?6h").isEmpty)  // DECOM
        #expect(run("\u{1B}[?6l").isEmpty)  // DECOM reset
    }

    @Test func escBackslashIsSilentlyIgnored() {
        // ESC \ is the 7-bit form of ST (String Terminator). After a string
        // sequence exits, the parser dispatches ESC \ as a normal ESC sequence.
        // StreamHandler should silently ignore it.
        #expect(run("\u{1B}\\").isEmpty)
    }

    @Test func escEqualsSetsKeypadApplicationMode() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        let bytes = Array("\u{1B}=".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.keypadApplication) == true)
    }

    @Test func escGreaterResetsKeypadApplicationMode() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        // First set the mode via ESC =
        var parser = VTParser()
        let setBytes = Array("\u{1B}=".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.keypadApplication) == true)
        // Then reset via ESC >
        let resetBytes = Array("\u{1B}>".utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.keypadApplication) == false)
    }

    @Test func osc1UpdatesTitleSameAsOsc0() {
        // OSC 1 (icon name) is treated the same as OSC 0/2 (window title).
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var titles: [String] = []
        handler.onTitleChanged = { titles.append($0) }
        var parser = VTParser()
        let bytes = Array("\u{1B}]1;my-icon\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(titles == ["my-icon"])
        #expect(handler.currentTitle == "my-icon")
    }

    @Test func osc7ParsesFileURL() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var dirs: [String] = []
        handler.onWorkingDirectoryChanged = { dirs.append($0) }
        var parser = VTParser()
        let bytes = Array("\u{1B}]7;file://myhost/Users/alice/projects\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(dirs == ["/Users/alice/projects"])
    }

    @Test func osc7IgnoresNonFileURL() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var dirs: [String] = []
        handler.onWorkingDirectoryChanged = { dirs.append($0) }
        var parser = VTParser()
        let bytes = Array("\u{1B}]7;http://example.com\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(dirs.isEmpty)
    }
}

@Suite("StreamHandler DA1 tests", .serialized)
struct StreamHandlerDA1Tests {

    @Test func da1RespondsWithVT220Capabilities() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        var parser = VTParser()
        // CSI ? 0 c (primary DA request)
        let bytes = Array("\u{1B}[?0c".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses == ["\u{1B}[?62;1;2;4;7;8;9;12;18;21;23;24;42c"])
    }
}

@Suite("StreamHandler DECALN tests", .serialized)
struct StreamHandlerDECALNTests {

    @Test func decalnFillsScreenWithEAndMovesCursorHome() {
        let screen = Screen(columns: 5, rows: 3)
        // Write some content first
        screen.write(GraphemeCluster(Character("A")), attributes: .default)
        screen.setCursorPos(row: 1, col: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        // ESC # 8 (DECALN)
        let bytes = Array("\u{1B}#8".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        // All cells should be 'E'
        for row in 0..<screen.rows {
            for col in 0..<screen.columns {
                #expect(screen.cell(at: col, row: row).codepoint == "E")
            }
        }
        // Cursor should be at home position
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
        // Dirty region should be full rebuild
        #expect(screen.consumeDirtyRegion().fullRebuild == true)
    }
}

@Suite("StreamHandler DEC mode tests", .serialized)
struct StreamHandlerDECModeTests {

    @Test func dsrReportsAbsolutePositionWhenOriginModeOff() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setCursorPos(row: 3, col: 4)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        var parser = VTParser()
        let bytes = Array("\u{1B}[6n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses == ["\u{1B}[4;5R"])
    }

    @Test func dsrReportsRelativePositionWhenOriginModeOn() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setScrollRegion(top: 1, bottom: 3)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        var parser = VTParser()

        // Enable origin mode via VT sequence so handler.modes stays in sync
        let setOrigin = Array("\u{1B}[?6h".utf8)
        setOrigin.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Move cursor to relative row 1 (absolute row 2)
        let cupBytes = Array("\u{1B}[2;5H".utf8)
        cupBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        let dsrBytes = Array("\u{1B}[6n".utf8)
        dsrBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        // Relative to scrollTop (1): absolute row 2 -> 2 - 1 + 1 = 2
        #expect(responses == ["\u{1B}[2;5R"])
    }

    @Test func saveAndRestoreCursorPreservesOriginMode() {
        let screen = Screen(columns: 10, rows: 5)
        screen.setScrollRegion(top: 1, bottom: 3)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable origin mode via VT sequence
        let setOrigin = Array("\u{1B}[?6h".utf8)
        setOrigin.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Move cursor to relative row 1, col 2 (absolute row 2)
        let cupBytes = Array("\u{1B}[2;3H".utf8)
        cupBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // DECSC (save cursor)
        let saveBytes = Array("\u{1B}7".utf8)
        saveBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Disable origin mode and move cursor elsewhere
        let resetOrigin = Array("\u{1B}[?6l".utf8)
        resetOrigin.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        let moveBytes = Array("\u{1B}[5;5H".utf8)
        moveBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // DECRC (restore cursor)
        let restoreBytes = Array("\u{1B}8".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Cursor should restore to absolute row 2, col 2
        #expect(screen.cursorRow == 2)
        #expect(screen.cursorCol == 2)
        // Origin mode should be restored to true
        #expect(screen.originMode == true)
    }

    @Test func reverseVideoTriggersFullRedraw() {
        let screen = Screen(columns: 10, rows: 2)
        screen.consumeDirtyRegion() // clear initial full rebuild
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        let bytes = Array("\u{1B}[?5h".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.reverseVideo == true)
        #expect(screen.consumeDirtyRegion().fullRebuild == true)
    }
}
