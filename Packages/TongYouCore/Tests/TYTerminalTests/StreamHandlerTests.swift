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

    @Test func mode2027OffWritesScalarsIndependently() {
        // Turn off grapheme clustering: ZWJ sequence should be written
        // as independent scalars.
        let screen = processVTScreen("\u{1B}[?2027l👨‍👩‍👧‍👦", columns: 10, rows: 2)
        // Each scalar is a separate cell (width 1 or 2 depending on the scalar).
        // The first scalar (👨) is wide, so it occupies cell 0 (wide) and cell 1 (continuation).
        // Then the ZWJ scalar occupies cell 2.
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 2, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 2, row: 0).content.firstScalar?.value == 0x200D) // ZWJ
    }

    @Test func mode2027OffThenOnRestoresClustering() {
        let seq = "\u{1B}[?2027l👋🏻\u{1B}[?2027h👋🏻"
        let screen = processVTScreen(seq, columns: 10, rows: 2)
        // First emoji (mode off): scalars written independently.
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 2, row: 0).content.scalarCount == 1)
        // Second emoji (mode on): combined into one cluster.
        #expect(screen.cell(at: 4, row: 0).content.scalarCount == 2)
        #expect(screen.cell(at: 4, row: 0).width == .wide)
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

    @Test func decrqm1004ReportsState() {
        // Default is reset (2).
        let (_, writtenDefault) = drive("\u{1B}[?1004$p")
        #expect(String(bytes: writtenDefault, encoding: .ascii) == "\u{1B}[?1004;2$y")

        // After DECSET it is set (1).
        let (_, writtenSet) = drive("\u{1B}[?1004h\u{1B}[?1004$p")
        #expect(String(bytes: writtenSet, encoding: .ascii) == "\u{1B}[?1004;1$y")
    }

    @Test func decrqm1016ReportsState() {
        // Default is reset (2).
        let (_, writtenDefault) = drive("\u{1B}[?1016$p")
        #expect(String(bytes: writtenDefault, encoding: .ascii) == "\u{1B}[?1016;2$y")

        // After DECSET 1016 it is set (1).
        let (_, writtenSet) = drive("\u{1B}[?1016h\u{1B}[?1016$p")
        #expect(String(bytes: writtenSet, encoding: .ascii) == "\u{1B}[?1016;1$y")

        // After DECRST 1016 it is reset (2).
        let (_, writtenReset) = drive("\u{1B}[?1016h\u{1B}[?1016l\u{1B}[?1016$p")
        #expect(String(bytes: writtenReset, encoding: .ascii) == "\u{1B}[?1016;2$y")
    }

    @Test func decrqm2004ReportsState() {
        // Default is reset (2).
        let (_, writtenDefault) = drive("\u{1B}[?2004$p")
        #expect(String(bytes: writtenDefault, encoding: .ascii) == "\u{1B}[?2004;2$y")

        // After DECSET 2004 it is set (1).
        let (_, writtenSet) = drive("\u{1B}[?2004h\u{1B}[?2004$p")
        #expect(String(bytes: writtenSet, encoding: .ascii) == "\u{1B}[?2004;1$y")

        // After DECRST 2004 it is reset (2).
        let (_, writtenReset) = drive("\u{1B}[?2004h\u{1B}[?2004l\u{1B}[?2004$p")
        #expect(String(bytes: writtenReset, encoding: .ascii) == "\u{1B}[?2004;2$y")
    }

    @Test func decrqm2027ReportsState() {
        // Default is set (1) — grapheme clustering is on by default in TongYou.
        let (_, writtenDefault) = drive("\u{1B}[?2027$p")
        #expect(String(bytes: writtenDefault, encoding: .ascii) == "\u{1B}[?2027;1$y")

        // After DECRST 2027 it is reset (2).
        let (_, writtenReset) = drive("\u{1B}[?2027l\u{1B}[?2027$p")
        #expect(String(bytes: writtenReset, encoding: .ascii) == "\u{1B}[?2027;2$y")

        // After DECSET 2027 it is set (1) again.
        let (_, writtenSet) = drive("\u{1B}[?2027l\u{1B}[?2027h\u{1B}[?2027$p")
        #expect(String(bytes: writtenSet, encoding: .ascii) == "\u{1B}[?2027;1$y")
    }

    @Test func decrqm2031ReportsState() {
        // Default is reset (2).
        let (_, writtenDefault) = drive("\u{1B}[?2031$p")
        #expect(String(bytes: writtenDefault, encoding: .ascii) == "\u{1B}[?2031;2$y")

        // After DECSET 2031 it is set (1).
        let (_, writtenSet) = drive("\u{1B}[?2031h\u{1B}[?2031$p")
        #expect(String(bytes: writtenSet, encoding: .ascii) == "\u{1B}[?2031;1$y")

        // After DECRST 2031 it is reset (2).
        let (_, writtenReset) = drive("\u{1B}[?2031h\u{1B}[?2031l\u{1B}[?2031$p")
        #expect(String(bytes: writtenReset, encoding: .ascii) == "\u{1B}[?2031;2$y")
    }

    @Test func decrqm2031DSR996ReportsDark() {
        var handler = StreamHandler(screen: Screen(columns: 10, rows: 2))
        var response: Data?
        handler.onWriteBack = { response = $0 }
        handler.onColorSchemeQuery = { true }
        var parser = VTParser()
        let bytes = Array("\u{1B}[?996n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(String(data: response!, encoding: .ascii) == "\u{1B}[?997;1n")
    }

    @Test func decrqm2031DSR996ReportsLight() {
        var handler = StreamHandler(screen: Screen(columns: 10, rows: 2))
        var response: Data?
        handler.onWriteBack = { response = $0 }
        handler.onColorSchemeQuery = { false }
        var parser = VTParser()
        let bytes = Array("\u{1B}[?996n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(String(data: response!, encoding: .ascii) == "\u{1B}[?997;2n")
    }

    @Test func decrqm2031DSR997ReportsDark() {
        var handler = StreamHandler(screen: Screen(columns: 10, rows: 2))
        var response: Data?
        handler.onWriteBack = { response = $0 }
        handler.onColorSchemeQuery = { true }
        var parser = VTParser()
        let bytes = Array("\u{1B}[?997n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(String(data: response!, encoding: .ascii) == "\u{1B}[?997;1n")
    }

    @Test func decrqm2031DSR997ReportsLight() {
        var handler = StreamHandler(screen: Screen(columns: 10, rows: 2))
        var response: Data?
        handler.onWriteBack = { response = $0 }
        handler.onColorSchemeQuery = { false }
        var parser = VTParser()
        let bytes = Array("\u{1B}[?997n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(String(data: response!, encoding: .ascii) == "\u{1B}[?997;2n")
    }

    @Test func decrqmUnrelatedModeIsSilentlyDropped() {
        let (_, written) = drive("\u{1B}[?9999$p")
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

@Suite("StreamHandler color scheme reporting (mode 2031) tests", .serialized)
struct StreamHandlerColorSchemeReportingTests {

    /// Drive a sequence of bytes through the handler, recording every
    /// `onColorSchemeReportingChanged` notification in order.
    private func run(_ s: String) -> [Bool] {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var events: [Bool] = []
        handler.onColorSchemeReportingChanged = { events.append($0) }
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        return events
    }

    @Test func colorSchemeReportingInitiallyOff() {
        let screen = Screen(columns: 10, rows: 2)
        let handler = StreamHandler(screen: screen)
        #expect(handler.modes.isSet(.colorSchemeReporting) == false)
    }

    @Test func colorSchemeReportingModeToggles() {
        #expect(run("\u{1B}[?2031h") == [true])
        #expect(run("\u{1B}[?2031l") == [false])
        #expect(run("\u{1B}[?2031h\u{1B}[?2031l") == [true, false])
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

    @Test func saveAndRestoreModesWithQuestionU() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable focus events and reverse video
        let setBytes = Array("\u{1B}[?1004h\u{1B}[?5h".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.focusEvents) == true)
        #expect(screen.reverseVideo == true)

        // Save modes
        let saveBytes = Array("\u{1B}[?s".utf8)
        saveBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Disable focus events and reverse video
        let resetBytes = Array("\u{1B}[?1004l\u{1B}[?5l".utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.focusEvents) == false)
        #expect(screen.reverseVideo == false)

        // Restore modes via CSI ? u
        let restoreBytes = Array("\u{1B}[?u".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.focusEvents) == true)
        #expect(screen.reverseVideo == true)
    }

    @Test func saveAndRestoreModesWithQuestionR() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable origin mode
        let setBytes = Array("\u{1B}[?6h".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.originMode) == true)
        #expect(screen.originMode == true)

        // Save modes
        let saveBytes = Array("\u{1B}[?s".utf8)
        saveBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Disable origin mode
        let resetBytes = Array("\u{1B}[?6l".utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.originMode) == false)
        #expect(screen.originMode == false)

        // Restore modes via CSI ? r
        let restoreBytes = Array("\u{1B}[?r".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.originMode) == true)
        #expect(screen.originMode == true)
    }

    @Test func restoreModesWithoutSaveIsNoOp() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Change a mode without saving
        let setBytes = Array("\u{1B}[?5h".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.reverseVideo == true)

        // Restore without prior save should not crash or change state
        let restoreBytes = Array("\u{1B}[?u".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.reverseVideo == true)
    }

    @Test func saveRestoreModesAltScreen() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Write to main screen and save modes
        let mainBytes = Array("MAIN".utf8)
        mainBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.cell(at: 0, row: 0).codepoint == "M")

        // Save modes
        let saveBytes = Array("\u{1B}[?s".utf8)
        saveBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Enter alt screen (not saved state)
        let altBytes = Array("\u{1B}[?1049hALT".utf8)
        altBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")

        // Restore modes (should switch back to main screen since saved state has altScreen=false)
        let restoreBytes = Array("\u{1B}[?u".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.altScreen) == false)
        #expect(screen.cell(at: 0, row: 0).codepoint == "M")
    }

    @Test func risClearsSavedModes() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable and save a mode
        let setBytes = Array("\u{1B}[?5h\u{1B}[?s".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Full reset
        let risBytes = Array("\u{1B}c".utf8)
        risBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        // Change mode after reset
        let resetBytes = Array("\u{1B}[?5l".utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.reverseVideo == false)

        // Restore after RIS should be no-op because saved modes were cleared
        let restoreBytes = Array("\u{1B}[?u".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(screen.reverseVideo == false)
    }

    @Test func saveRestoreModesColorSchemeReporting() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        var colorSchemeEvents: [Bool] = []
        handler.onColorSchemeReportingChanged = { colorSchemeEvents.append($0) }

        // Enable mode 2031 and save modes
        let setBytes = Array("\u{1B}[?2031h\u{1B}[?s".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.colorSchemeReporting) == true)
        #expect(colorSchemeEvents == [true])

        // Disable mode 2031
        let resetBytes = Array("\u{1B}[?2031l".utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.colorSchemeReporting) == false)
        #expect(colorSchemeEvents == [true, false])

        // Restore modes (should re-enable mode 2031)
        let restoreBytes = Array("\u{1B}[?u".utf8)
        restoreBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(handler.modes.isSet(.colorSchemeReporting) == true)
        #expect(colorSchemeEvents == [true, false, true])
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

    @Test func osc10QueryRespondsWithForegroundColor() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        handler.onDynamicColorQuery = { oscNum in
            #expect(oscNum == 10)
            return RGBColor(r: 0xDC, g: 0xDC, b: 0xDC)
        }
        var parser = VTParser()
        let bytes = Array("\u{1B}]10;?\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses == ["\u{1B}]10;rgb:DCDC/DCDC/DCDC\u{07}"])
    }

    @Test func osc11QueryRespondsWithBackgroundColor() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        handler.onDynamicColorQuery = { oscNum in
            #expect(oscNum == 11)
            return RGBColor(r: 0x1E, g: 0x1E, b: 0x26)
        }
        var parser = VTParser()
        let bytes = Array("\u{1B}]11;?\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses == ["\u{1B}]11;rgb:1E1E/1E1E/2626\u{07}"])
    }

    @Test func osc10SetColorWithHex() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var colors: [(Int, RGBColor)] = []
        handler.onDynamicColorSet = { colors.append(($0, $1)) }
        var parser = VTParser()
        let bytes = Array("\u{1B}]10;#ff0000\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(colors.count == 1)
        #expect(colors[0].0 == 10)
        #expect(colors[0].1 == RGBColor(r: 0xFF, g: 0x00, b: 0x00))
    }

    @Test func osc10QueryWithoutHandlerIsSilent() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        // No onDynamicColorQuery set
        var parser = VTParser()
        let bytes = Array("\u{1B}]10;?\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses.isEmpty)
    }

    @Test func osc10SetInvalidColorIsIgnored() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var colors: [(Int, RGBColor)] = []
        handler.onDynamicColorSet = { colors.append(($0, $1)) }
        var parser = VTParser()
        let bytes = Array("\u{1B}]10;not-a-color\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(colors.isEmpty)
    }
}

@Suite("StreamHandler DA1 tests", .serialized)
struct StreamHandlerDA1Tests {

    @Test func da1RespondsWithVT500Capabilities() {
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
        #expect(responses == ["\u{1B}[?65;1;9;12;18;22c"])
    }

    @Test func da1WithoutQuestionMarkResponds() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var responses: [String] = []
        handler.onWriteBack = { responses.append(String(data: $0, encoding: .utf8)!) }
        var parser = VTParser()
        // CSI 0 c (primary DA request without ?)
        let bytes = Array("\u{1B}[0c".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        #expect(responses == ["\u{1B}[?65;1;9;12;18;22c"])
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

@Suite("StreamHandler ANSI mode tests", .serialized)
struct StreamHandlerANSIModeTests {

    /// Drive a sequence of bytes through the handler and return the screen.
    private func drive(_ s: String, columns: Int = 10, rows: Int = 5) -> Screen {
        let screen = Screen(columns: columns, rows: rows)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()
        return screen
    }

    // MARK: - IRM (Insert/Replace Mode, mode 4)

    @Test func irmInitiallyDisabled() {
        let screen = drive("")
        #expect(screen.insertMode == false)
    }

    @Test func rmMode4DisablesInsertMode() {
        let screen = drive("\u{1B}[4h\u{1B}[4l")
        #expect(screen.insertMode == false)
    }

    @Test func irmInsertsCharactersAtCursor() {
        // Write "ABC", move cursor back to column 1, enable IRM, write "X"
        // Result should be "AXBC" instead of "AXC"
        let screen = drive("ABC\u{1B}[D\u{1B}[D\u{1B}[4hX")
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "X")
        #expect(screen.cell(at: 2, row: 0).codepoint == "B")
        #expect(screen.cell(at: 3, row: 0).codepoint == "C")
    }

    @Test func irmInsertShiftsContentRight() {
        // Fill a line, enable IRM, insert in the middle
        let screen = drive("HELLO\u{1B}[3G\u{1B}[4hX", columns: 10, rows: 3)
        // Cursor at column 3 (0-indexed: 2), insert 'X'
        // Result: "HEXLLO" (H E X L L O) — all chars after col 2 shift right
        #expect(screen.cell(at: 0, row: 0).codepoint == "H")
        #expect(screen.cell(at: 1, row: 0).codepoint == "E")
        #expect(screen.cell(at: 2, row: 0).codepoint == "X")
        #expect(screen.cell(at: 3, row: 0).codepoint == "L")
        #expect(screen.cell(at: 4, row: 0).codepoint == "L")
        #expect(screen.cell(at: 5, row: 0).codepoint == "O")
    }

    @Test func rmMode4RestoresReplaceMode() {
        // Enable IRM, then disable it, then write
        let screen = drive("AB\u{1B}[4h\u{1B}[4lC")
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
    }

    // MARK: - LNM (Line Feed/New Line Mode, mode 20)

    @Test func lnmInitiallyDisabled() {
        let screen = drive("")
        // When LNM is disabled, LF should only move down, not to column 0
        // This is the default state
        let screen2 = drive("AB\u{1B}[H\nC")
        #expect(screen2.cursorCol == 1) // LF only, no CR
        #expect(screen2.cursorRow == 1)
    }

    @Test func smMode20EnablesLNM() {
        let screen = Screen(columns: 10, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable LNM
        let setBytes = Array("\u{1B}[20h".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        #expect(handler.modes.isSet(.newline) == true)
    }

    @Test func lnmMakesLFActAsNewline() {
        // With LNM enabled, LF should act as CRLF
        let screen = drive("AB\u{1B}[H\u{1B}[20h\nC")
        // After LF with LNM: should be at column 0, row 1
        #expect(screen.cell(at: 0, row: 1).codepoint == "C")
        #expect(screen.cursorCol == 1)
        #expect(screen.cursorRow == 1)
    }

    @Test func rmMode20DisablesLNM() {
        let screen = Screen(columns: 10, rows: 5)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        // Enable then disable LNM
        let setBytes = Array("\u{1B}[20h\u{1B}[20l".utf8)
        setBytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        #expect(handler.modes.isSet(.newline) == false)
    }

    @Test func vtAndFFRespectLNM() {
        // VT (0x0B) and FF (0x0C) should also respect LNM mode
        let screen = drive("\u{1B}[20hA\u{0B}B", columns: 10, rows: 3)
        // VT with LNM should act as newline
        #expect(screen.cell(at: 0, row: 1).codepoint == "B")
    }

    // MARK: - Unrecognized ANSI modes

    @Test func unsupportedANSIModeTriggersCallback() {
        let screen = Screen(columns: 10, rows: 2)
        var handler = StreamHandler(screen: screen)
        var unhandled: [String] = []
        handler.onUnhandledSequence = { unhandled.append($0) }
        var parser = VTParser()

        // Mode 1 is cursor keys (DEC mode with ?), but without ? it's ANSI
        // Mode 3 is not a standard ANSI mode
        let bytes = Array("\u{1B}[3h".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in handler.handle(action) }
        }
        handler.flush()

        #expect(unhandled == ["ANSI SM/RM mode 3 not implemented"])
    }
}

@Suite("StreamHandler ESC charset select tests", .serialized)
struct StreamHandlerESCCharsetSelectTests {

    /// Drive bytes and collect unhandled sequences.
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

    @Test func escPercentAtIsAcceptedSilently() {
        // ESC % @ — Select default character set
        #expect(run("\u{1B}%@").isEmpty)
    }

    @Test func escPercentGIsAcceptedSilently() {
        // ESC % G — Select UTF-8 character set
        #expect(run("\u{1B}%G").isEmpty)
    }

    @Test func escPercentUnknownIsReported() {
        // ESC % X — Unknown charset
        #expect(run("\u{1B}%X") == ["ESC %X (charset select) not implemented"])
    }
}
