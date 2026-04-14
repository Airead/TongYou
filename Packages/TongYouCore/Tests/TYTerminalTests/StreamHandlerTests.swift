import Foundation
import Testing
@testable import TYTerminal

@Suite("StreamHandler grapheme cluster tests")
struct StreamHandlerGraphemeClusterTests {

    /// Feed raw bytes through VTParser → StreamHandler → Screen, return screen.
    private func process(_ s: String, columns: Int = 80, rows: Int = 24) -> Screen {
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

    @Test func zwjSequenceRendersAsOneCell() {
        let screen = process("👨‍👩‍👧‍👦", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 7)
        #expect(screen.cursorCol == 2)
    }

    @Test func skinToneModifierRendersAsOneCell() {
        let screen = process("👋🏻", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 2)
        #expect(screen.cursorCol == 2)
    }

    @Test func flagEmojiRendersAsOneCell() {
        let screen = process("🇨🇳", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).width == .wide)
        #expect(screen.cell(at: 1, row: 0).width == .continuation)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 2)
        #expect(screen.cursorCol == 2)
    }

    @Test func mixedAsciiAndEmoji() {
        let screen = process("A👨‍👩‍👧‍👦B", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 0, row: 0).width == .normal)
        #expect(screen.cell(at: 1, row: 0).content.scalarCount == 7)
        #expect(screen.cell(at: 1, row: 0).width == .wide)
        #expect(screen.cell(at: 3, row: 0).content.scalarCount == 1)
        #expect(screen.cell(at: 3, row: 0).width == .normal)
        #expect(screen.cursorCol == 4)
    }

    @Test func graphemeClusterFlushedBeforeCursorMove() {
        let screen = process("A\u{1B}[H", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
    }

    @Test func simpleAsciiStillWorks() {
        let screen = process("Hello", columns: 10, rows: 2)
        #expect(screen.cell(at: 0, row: 0).codepoint == "H")
        #expect(screen.cell(at: 4, row: 0).codepoint == "o")
        #expect(screen.cursorCol == 5)
    }
}
