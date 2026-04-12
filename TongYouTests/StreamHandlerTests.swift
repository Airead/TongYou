import Foundation
import Testing
@testable import TongYou

@Suite struct StreamHandlerTests {

    // MARK: - Helpers

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
        return screen
    }

    /// Feed raw bytes and return both screen and handler.
    private func processWithHandler(
        _ s: String,
        columns: Int = 80,
        rows: Int = 24,
        configure: ((inout StreamHandler) -> Void)? = nil
    ) -> (Screen, StreamHandler) {
        let screen = Screen(columns: columns, rows: rows)
        var handler = StreamHandler(screen: screen)
        configure?(&handler)
        var parser = VTParser()
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in
                handler.handle(action)
            }
        }
        return (screen, handler)
    }

    // MARK: - Print

    @Test func printText() {
        let screen = process("Hello")
        #expect(screen.cell(at: 0, row: 0).codepoint == "H")
        #expect(screen.cell(at: 4, row: 0).codepoint == "o")
        #expect(screen.cursorCol == 5)
    }

    // MARK: - Cursor Movement

    @Test func cursorMovement() {
        // Print, move cursor home, verify
        let screen = process("AB\u{1B}[H")
        #expect(screen.cursorRow == 0)
        #expect(screen.cursorCol == 0)
    }

    @Test func cursorPosition() {
        let screen = process("\u{1B}[5;10H")
        #expect(screen.cursorRow == 4) // 1-based → 0-based
        #expect(screen.cursorCol == 9)
    }

    @Test func cursorUpDown() {
        let screen = process("\u{1B}[5;1H\u{1B}[2A")
        #expect(screen.cursorRow == 2) // row 4 - 2 = 2
    }

    @Test func cursorForwardBackward() {
        let screen = process("\u{1B}[1;10H\u{1B}[3D")
        #expect(screen.cursorCol == 6) // col 9 - 3 = 6
    }

    // MARK: - Erase

    @Test func eraseDisplayBelow() {
        let screen = process("ABCDEF\u{1B}[1;4H\u{1B}[J", columns: 6, rows: 1)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
        #expect(screen.cell(at: 2, row: 0).codepoint == "C")
        #expect(screen.cell(at: 3, row: 0) == Cell.empty)
    }

    @Test func eraseLineComplete() {
        let screen = process("Hello\u{1B}[1;3H\u{1B}[2K", columns: 10, rows: 1)
        for col in 0..<5 {
            #expect(screen.cell(at: col, row: 0) == Cell.empty)
        }
    }

    // MARK: - SGR Colors

    @Test func sgrRedForeground() {
        let screen = process("\u{1B}[31mA")
        let cell = screen.cell(at: 0, row: 0)
        #expect(cell.codepoint == "A")
        #expect(cell.attributes.fgColor == .indexed(1)) // red
    }

    @Test func sgrBoldGreen() {
        let screen = process("\u{1B}[1;32mX")
        let cell = screen.cell(at: 0, row: 0)
        #expect(cell.attributes.flags.contains(.bold))
        #expect(cell.attributes.fgColor == .indexed(2)) // green
    }

    @Test func sgrReset() {
        let screen = process("\u{1B}[1;31mA\u{1B}[0mB")
        let cellA = screen.cell(at: 0, row: 0)
        let cellB = screen.cell(at: 1, row: 0)
        #expect(cellA.attributes.fgColor == .indexed(1))
        #expect(cellA.attributes.flags.contains(.bold))
        #expect(cellB.attributes == .default)
    }

    @Test func sgr256Color() {
        let screen = process("\u{1B}[38;5;196mR")
        let cell = screen.cell(at: 0, row: 0)
        #expect(cell.attributes.fgColor == .indexed(196))
    }

    @Test func sgrTrueColor() {
        let screen = process("\u{1B}[38;2;100;200;50mG")
        let cell = screen.cell(at: 0, row: 0)
        #expect(cell.attributes.fgColor == .rgb(100, 200, 50))
    }

    // MARK: - Scroll Region

    @Test func scrollRegion() {
        // Set scroll region to rows 1-2 (1-based: 2-3)
        let screen = process("R0\r\nR1\r\nR2\r\nR3\u{1B}[2;3r\u{1B}[3;1H\u{1B}[S",
                             columns: 2, rows: 4)
        // Row 0 unaffected
        #expect(screen.cell(at: 0, row: 0).codepoint == "R")
        // Row 3 unaffected
        #expect(screen.cell(at: 0, row: 3).codepoint == "R")
    }

    // MARK: - Insert / Delete

    @Test func insertDeleteChars() {
        let screen = process("ABCDE\u{1B}[1;2H\u{1B}[2@", columns: 5, rows: 1)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0) == Cell.empty)
        #expect(screen.cell(at: 2, row: 0) == Cell.empty)
        #expect(screen.cell(at: 3, row: 0).codepoint == "B")
    }

    // MARK: - DEC Modes

    @Test func decsetCursorVisibility() {
        let (screen, _) = processWithHandler("\u{1B}[?25l")
        #expect(!screen.cursorVisible)
    }

    @Test func decsetAltScreen() {
        let (screen, handler) = processWithHandler("Hello\u{1B}[?1049h")
        // Should be on alt screen, content cleared
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(handler.modes.isSet(.altScreen))
    }

    // MARK: - ESC Sequences

    @Test func escReverseIndex() {
        let screen = process("AB\r\nCD\u{1B}[1;1H\u{1B}M", columns: 2, rows: 2)
        // ESC M at row 0 should scroll down
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cell(at: 0, row: 1).codepoint == "A")
    }

    @Test func escFullReset() {
        let (screen, handler) = processWithHandler("Hello\u{1B}c")
        #expect(screen.cell(at: 0, row: 0) == Cell.empty)
        #expect(screen.cursorCol == 0)
        #expect(screen.cursorRow == 0)
        #expect(handler.modes == TerminalModes())
    }

    // MARK: - OSC

    @Test func oscWindowTitle() {
        let screen = Screen(columns: 80, rows: 24)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        var title: String?
        handler.onTitleChanged = { title = $0 }

        let bytes = Array("\u{1B}]0;My Terminal\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in
                handler.handle(action)
            }
        }
        #expect(title == "My Terminal")
    }

    // MARK: - DSR

    @Test func deviceStatusReport() {
        let screen = Screen(columns: 80, rows: 24)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()

        var response: Data?
        handler.onWriteBack = { response = $0 }

        // Move to row 5, col 10 then request cursor position
        let bytes = Array("\u{1B}[5;10H\u{1B}[6n".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in
                handler.handle(action)
            }
        }
        #expect(response == Data("\u{1B}[5;10R".utf8))
    }

    // MARK: - Cursor Save/Restore

    @Test func cursorSaveRestore() {
        let screen = process("\u{1B}[5;10H\u{1B}7\u{1B}[1;1H\u{1B}8")
        #expect(screen.cursorRow == 4)
        #expect(screen.cursorCol == 9)
    }

    // MARK: - Repeat

    @Test func repeatCharacter() {
        let screen = process("A\u{1B}[3b", columns: 10, rows: 1)
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "A")
        #expect(screen.cell(at: 2, row: 0).codepoint == "A")
        #expect(screen.cell(at: 3, row: 0).codepoint == "A")
        #expect(screen.cursorCol == 4)
    }

    // MARK: - BEL

    @Test func belTriggersCallback() {
        let screen = Screen(columns: 80, rows: 24)
        var handler = StreamHandler(screen: screen)
        var parser = VTParser()
        var bellCount = 0
        handler.onBell = { bellCount += 1 }

        let bytes = Array("Hello\u{07}World\u{07}".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            parser.feed(ptr) { action in
                handler.handle(action)
            }
        }
        #expect(bellCount == 2)
    }

    @Test func belWithoutCallbackDoesNotCrash() {
        // BEL with no onBell callback should be safe
        let screen = process("A\u{07}B")
        #expect(screen.cell(at: 0, row: 0).codepoint == "A")
        #expect(screen.cell(at: 1, row: 0).codepoint == "B")
    }

    // MARK: - OSC 7727 (Shell Integration)

    private func feedOSC7727(_ input: String) -> (called: Bool, command: String?) {
        var called = false
        var command: String? = "SENTINEL"
        _ = processWithHandler(input) { handler in
            handler.onRunningCommandChanged = { cmd in
                called = true
                command = cmd
            }
        }
        return called ? (true, command) : (false, nil)
    }

    @Test func osc7727RunningCommand() {
        let result = feedOSC7727("\u{1B}]7727;running-command=zellij\u{07}")
        #expect(result.called)
        #expect(result.command == "zellij")
    }

    @Test func osc7727ShellPrompt() {
        let result = feedOSC7727("\u{1B}]7727;shell-prompt\u{07}")
        #expect(result.called)
        #expect(result.command == nil)
    }

    @Test func osc7727RunningCommandWithST() {
        let result = feedOSC7727("\u{1B}]7727;running-command=vim\u{1B}\\")
        #expect(result.called)
        #expect(result.command == "vim")
    }

    @Test func osc7727EmptyCommandIgnored() {
        let result = feedOSC7727("\u{1B}]7727;running-command=\u{07}")
        #expect(!result.called)
    }

    @Test func osc7727UnknownSubcommandIgnored() {
        let result = feedOSC7727("\u{1B}]7727;unknown-thing\u{07}")
        #expect(!result.called)
    }

    // MARK: - OSC 52 (Clipboard)

    /// Feed an OSC 52 sequence and return the clipboard text received (if any).
    private func feedOSC52(_ input: String) -> String? {
        var clipboardText: String?
        _ = processWithHandler(input) { handler in
            handler.onClipboardSet = { clipboardText = $0 }
        }
        return clipboardText
    }

    @Test func osc52SetClipboard() {
        // "Hello" base64 = "SGVsbG8=", terminated with BEL
        #expect(feedOSC52("\u{1B}]52;c;SGVsbG8=\u{07}") == "Hello")
    }

    @Test func osc52SetClipboardWithST() {
        // Terminated with ST (ESC \) instead of BEL
        #expect(feedOSC52("\u{1B}]52;c;SGVsbG8=\u{1B}\\") == "Hello")
    }

    @Test func osc52QueryIsRejected() {
        #expect(feedOSC52("\u{1B}]52;c;?\u{07}") == nil)
    }

    @Test func osc52InvalidBase64IsIgnored() {
        #expect(feedOSC52("\u{1B}]52;c;!!!\u{07}") == nil)
    }

    @Test func osc52EmptyPayloadIsIgnored() {
        #expect(feedOSC52("\u{1B}]52;c;\u{07}") == nil)
    }
}
