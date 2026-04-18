import Testing
import Foundation
@testable import TYAutomation
import TYTerminal

@Suite("AutomationKeySpec parsing")
struct AutomationKeySpecTests {

    // MARK: - Named keys

    @Test func parsesEnterAsReturnKeyCode() throws {
        let input = try AutomationKeySpec.parse("Enter")
        #expect(input.keyCode == 36)
        #expect(input.characters == "\r")
        #expect(!input.shift && !input.control && !input.option && !input.command)
    }

    @Test func returnIsAliasForEnter() throws {
        let input = try AutomationKeySpec.parse("Return")
        #expect(input.keyCode == 36)
    }

    @Test func escAndEscapeAreEquivalent() throws {
        let a = try AutomationKeySpec.parse("Esc")
        let b = try AutomationKeySpec.parse("Escape")
        #expect(a.keyCode == b.keyCode && a.keyCode == 53)
    }

    @Test func forwardDeleteAliases() throws {
        let a = try AutomationKeySpec.parse("Delete")
        let b = try AutomationKeySpec.parse("ForwardDelete")
        #expect(a.keyCode == 117)
        #expect(b.keyCode == 117)
    }

    @Test func arrowKeysParseToExpectedKeyCodes() throws {
        #expect(try AutomationKeySpec.parse("Up").keyCode    == 126)
        #expect(try AutomationKeySpec.parse("Down").keyCode  == 125)
        #expect(try AutomationKeySpec.parse("Left").keyCode  == 123)
        #expect(try AutomationKeySpec.parse("Right").keyCode == 124)
    }

    @Test func navigationKeys() throws {
        #expect(try AutomationKeySpec.parse("Home").keyCode     == 115)
        #expect(try AutomationKeySpec.parse("End").keyCode      == 119)
        #expect(try AutomationKeySpec.parse("PageUp").keyCode   == 116)
        #expect(try AutomationKeySpec.parse("PageDown").keyCode == 121)
        #expect(try AutomationKeySpec.parse("Insert").keyCode   == 114)
    }

    @Test func functionKeysF1ThroughF12() throws {
        let expected: [(String, UInt16)] = [
            ("F1", 122), ("F2", 120), ("F3", 99),  ("F4", 118),
            ("F5", 96),  ("F6", 97),  ("F7", 98),  ("F8", 100),
            ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
        ]
        for (name, keyCode) in expected {
            #expect(try AutomationKeySpec.parse(name).keyCode == keyCode, "expected \(name) → \(keyCode)")
        }
    }

    @Test func functionKeyBeyondF12IsRejected() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("F13") }
    }

    @Test func tabParsesToTabKeyCode() throws {
        let input = try AutomationKeySpec.parse("Tab")
        #expect(input.keyCode == 48)
        #expect(input.characters == "\t")
    }

    @Test func spaceParsesToSpaceKeyCode() throws {
        let input = try AutomationKeySpec.parse("Space")
        #expect(input.keyCode == 49)
        #expect(input.characters == " ")
    }

    @Test func backspaceParsesToBackspaceKeyCode() throws {
        let input = try AutomationKeySpec.parse("Backspace")
        #expect(input.keyCode == 51)
    }

    // MARK: - Character keys

    @Test func plainLetterIsLowercaseWithNoModifiers() throws {
        let input = try AutomationKeySpec.parse("a")
        #expect(input.characters == "a")
        #expect(input.charactersIgnoringModifiers == "a")
        #expect(!input.shift)
    }

    @Test func shiftedLetterProducesUppercaseCharacter() throws {
        let input = try AutomationKeySpec.parse("Shift+a")
        #expect(input.shift)
        #expect(input.characters == "A")
        #expect(input.charactersIgnoringModifiers == "a")
    }

    @Test func multiCharBaseIsRejected() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("abc") }
    }

    // MARK: - Modifiers

    @Test func ctrlCSetsControlFlag() throws {
        let input = try AutomationKeySpec.parse("Ctrl+C")
        #expect(input.control)
        #expect(input.charactersIgnoringModifiers == "c")
    }

    @Test func cmdTSetsCommandFlag() throws {
        let input = try AutomationKeySpec.parse("Cmd+T")
        #expect(input.command)
        #expect(input.charactersIgnoringModifiers == "t")
    }

    @Test func altLeftSetsOptionFlagAndArrowKeyCode() throws {
        let input = try AutomationKeySpec.parse("Alt+Left")
        #expect(input.option)
        #expect(input.keyCode == 123)
    }

    @Test func optIsAliasForAlt() throws {
        let a = try AutomationKeySpec.parse("Alt+Left")
        let b = try AutomationKeySpec.parse("Opt+Left")
        let c = try AutomationKeySpec.parse("Option+Left")
        #expect(a.option && b.option && c.option)
        #expect(a.keyCode == b.keyCode && b.keyCode == c.keyCode)
    }

    @Test func shiftTabSetsShiftWithTabKeyCode() throws {
        let input = try AutomationKeySpec.parse("Shift+Tab")
        #expect(input.shift)
        #expect(input.keyCode == 48)
    }

    @Test func allModifiersTogether() throws {
        let input = try AutomationKeySpec.parse("Shift+Cmd+Opt+Ctrl+A")
        #expect(input.shift && input.command && input.option && input.control)
        #expect(input.characters == "A")
    }

    @Test func modifiersAreCaseInsensitive() throws {
        let a = try AutomationKeySpec.parse("ctrl+c")
        let b = try AutomationKeySpec.parse("CTRL+c")
        #expect(a.control && b.control)
    }

    @Test func whitespaceAroundPlusIsTolerated() throws {
        let input = try AutomationKeySpec.parse("Ctrl + Alt + Left")
        #expect(input.control && input.option)
        #expect(input.keyCode == 123)
    }

    // MARK: - Invalid inputs

    @Test func emptyStringIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("") }
    }

    @Test func onlyWhitespaceIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("   ") }
    }

    @Test func trailingPlusIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("Ctrl+") }
    }

    @Test func leadingPlusIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("+C") }
    }

    @Test func duplicateModifierIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("Ctrl+Ctrl+C") }
    }

    @Test func unknownModifierIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("Hyper+C") }
    }

    @Test func unknownKeyIsInvalid() {
        #expect(throws: AutomationError.self) { _ = try AutomationKeySpec.parse("Wiggle") }
    }

    // MARK: - Round-trip through KeyEncoder

    @Test func ctrlCProducesSIGINTByte() throws {
        let input = try AutomationKeySpec.parse("Ctrl+C")
        let options = KeyEncoder.Options(appCursorMode: false, optionAsAlt: true)
        let data = try #require(KeyEncoder.encode(input, options: options))
        #expect(Array(data) == [0x03])
    }

    @Test func enterProducesCarriageReturn() throws {
        let input = try AutomationKeySpec.parse("Enter")
        let options = KeyEncoder.Options(appCursorMode: false, optionAsAlt: true)
        let data = try #require(KeyEncoder.encode(input, options: options))
        #expect(Array(data) == [0x0D])
    }

    @Test func leftArrowProducesCSISequence() throws {
        let input = try AutomationKeySpec.parse("Left")
        let options = KeyEncoder.Options(appCursorMode: false, optionAsAlt: true)
        let data = try #require(KeyEncoder.encode(input, options: options))
        #expect(Array(data) == [0x1B, 0x5B, 0x44]) // ESC [ D
    }
}
