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

@Suite("StreamHandler grapheme cluster tests")
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

@Suite("StreamHandler ACS tests")
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
