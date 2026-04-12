import Foundation
import Testing
@testable import TongYou

struct KeyEncoderTests {

    // MARK: - Helper

    private func input(
        keyCode: UInt16 = 0,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        shift: Bool = false,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false
    ) -> KeyEncoder.KeyInput {
        KeyEncoder.KeyInput(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            shift: shift,
            control: control,
            option: option,
            command: command
        )
    }

    private let normalOpts = KeyEncoder.Options(appCursorMode: false, optionAsAlt: true)
    private let appOpts = KeyEncoder.Options(appCursorMode: true, optionAsAlt: true)
    private let noAltOpts = KeyEncoder.Options(appCursorMode: false, optionAsAlt: false)

    // MARK: - Command Key

    @Test func commandKeyReturnsNil() {
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a", command: true),
            options: normalOpts
        )
        #expect(result == nil)
    }

    // MARK: - Arrow Keys (no modifier)

    @Test func arrowUpNormal() {
        let result = KeyEncoder.encode(input(keyCode: 126), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x41]))  // ESC[A
    }

    @Test func arrowUpAppCursor() {
        let result = KeyEncoder.encode(input(keyCode: 126), options: appOpts)
        #expect(result == Data([0x1B, 0x4F, 0x41]))  // ESCOA
    }

    @Test func arrowDownNormal() {
        let result = KeyEncoder.encode(input(keyCode: 125), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x42]))  // ESC[B
    }

    @Test func arrowRightNormal() {
        let result = KeyEncoder.encode(input(keyCode: 124), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x43]))  // ESC[C
    }

    @Test func arrowLeftNormal() {
        let result = KeyEncoder.encode(input(keyCode: 123), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x44]))  // ESC[D
    }

    // MARK: - Arrow Keys (with modifiers)

    @Test func shiftArrowUp() {
        // Shift+Up → ESC[1;2A  (mod = 1 + 1 = 2)
        let result = KeyEncoder.encode(
            input(keyCode: 126, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]))
    }

    @Test func altArrowUp() {
        // Alt+Up → ESC[1;3A  (mod = 1 + 2 = 3)
        let result = KeyEncoder.encode(
            input(keyCode: 126, option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x41]))
    }

    @Test func ctrlArrowUp() {
        // Ctrl+Up → ESC[1;5A  (mod = 1 + 4 = 5)
        let result = KeyEncoder.encode(
            input(keyCode: 126, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]))
    }

    @Test func shiftCtrlArrowRight() {
        // Shift+Ctrl+Right → ESC[1;6C  (mod = 1 + 1 + 4 = 6)
        let result = KeyEncoder.encode(
            input(keyCode: 124, shift: true, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x36, 0x43]))
    }

    @Test func shiftAltCtrlArrowLeft() {
        // Shift+Alt+Ctrl+Left → ESC[1;8D  (mod = 1 + 1 + 2 + 4 = 8)
        let result = KeyEncoder.encode(
            input(keyCode: 123, shift: true, control: true, option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x44]))
    }

    @Test func modifiedArrowIgnoresAppCursorMode() {
        // With modifiers, app cursor mode is ignored: always ESC[1;{mod}A
        let result = KeyEncoder.encode(
            input(keyCode: 126, shift: true),
            options: appOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]))
    }

    // MARK: - Navigation Keys

    @Test func homeKey() {
        let result = KeyEncoder.encode(input(keyCode: 115), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x48]))  // ESC[H
    }

    @Test func endKey() {
        let result = KeyEncoder.encode(input(keyCode: 119), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x46]))  // ESC[F
    }

    @Test func shiftHome() {
        // Shift+Home → ESC[1;2H
        let result = KeyEncoder.encode(
            input(keyCode: 115, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x48]))
    }

    @Test func ctrlEnd() {
        // Ctrl+End → ESC[1;5F
        let result = KeyEncoder.encode(
            input(keyCode: 119, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x46]))
    }

    @Test func deleteKey() {
        let result = KeyEncoder.encode(input(keyCode: 117), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x33, 0x7E]))  // ESC[3~
    }

    @Test func shiftDelete() {
        // Shift+Delete → ESC[3;2~
        let result = KeyEncoder.encode(
            input(keyCode: 117, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x33, 0x3B, 0x32, 0x7E]))
    }

    @Test func insertKey() {
        let result = KeyEncoder.encode(input(keyCode: 114), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x32, 0x7E]))  // ESC[2~
    }

    @Test func pageUpKey() {
        let result = KeyEncoder.encode(input(keyCode: 116), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x35, 0x7E]))  // ESC[5~
    }

    @Test func pageDownKey() {
        let result = KeyEncoder.encode(input(keyCode: 121), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x36, 0x7E]))  // ESC[6~
    }

    @Test func ctrlPageUp() {
        // Ctrl+PageUp → ESC[5;5~
        let result = KeyEncoder.encode(
            input(keyCode: 116, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x35, 0x3B, 0x35, 0x7E]))
    }

    // MARK: - Function Keys (no modifier)

    @Test func f1Key() {
        let result = KeyEncoder.encode(input(keyCode: 122), options: normalOpts)
        #expect(result == Data([0x1B, 0x4F, 0x50]))  // ESCOP
    }

    @Test func f2Key() {
        let result = KeyEncoder.encode(input(keyCode: 120), options: normalOpts)
        #expect(result == Data([0x1B, 0x4F, 0x51]))  // ESCOQ
    }

    @Test func f3Key() {
        let result = KeyEncoder.encode(input(keyCode: 99), options: normalOpts)
        #expect(result == Data([0x1B, 0x4F, 0x52]))  // ESCOR
    }

    @Test func f4Key() {
        let result = KeyEncoder.encode(input(keyCode: 118), options: normalOpts)
        #expect(result == Data([0x1B, 0x4F, 0x53]))  // ESCOS
    }

    @Test func f5Key() {
        let result = KeyEncoder.encode(input(keyCode: 96), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x35, 0x7E]))  // ESC[15~
    }

    @Test func f12Key() {
        let result = KeyEncoder.encode(input(keyCode: 111), options: normalOpts)
        #expect(result == Data([0x1B, 0x5B, 0x32, 0x34, 0x7E]))  // ESC[24~
    }

    // MARK: - Function Keys (with modifiers)

    @Test func shiftF1() {
        // Shift+F1 → ESC[1;2P
        let result = KeyEncoder.encode(
            input(keyCode: 122, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x50]))
    }

    @Test func ctrlF5() {
        // Ctrl+F5 → ESC[15;5~
        let result = KeyEncoder.encode(
            input(keyCode: 96, control: true),
            options: normalOpts
        )
        // ESC [ 1 5 ; 5 ~
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x35, 0x3B, 0x35, 0x7E]))
    }

    @Test func shiftF3() {
        // Shift+F3 → ESC[13;2~ (F3 uses tilde style with modifiers)
        let result = KeyEncoder.encode(
            input(keyCode: 99, shift: true),
            options: normalOpts
        )
        // ESC [ 1 3 ; 2 ~
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x7E]))
    }

    @Test func altF12() {
        // Alt+F12 → ESC[24;3~
        let result = KeyEncoder.encode(
            input(keyCode: 111, option: true),
            options: normalOpts
        )
        // ESC [ 2 4 ; 3 ~
        #expect(result == Data([0x1B, 0x5B, 0x32, 0x34, 0x3B, 0x33, 0x7E]))
    }

    // MARK: - Return, Backspace, Tab, Escape

    @Test func returnKey() {
        let result = KeyEncoder.encode(input(keyCode: 36), options: normalOpts)
        #expect(result == Data([0x0D]))
    }

    @Test func backspaceKey() {
        let result = KeyEncoder.encode(input(keyCode: 51), options: normalOpts)
        #expect(result == Data([0x7F]))
    }

    @Test func altBackspace() {
        let result = KeyEncoder.encode(
            input(keyCode: 51, option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x7F]))
    }

    @Test func ctrlBackspace() {
        let result = KeyEncoder.encode(
            input(keyCode: 51, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x08]))  // BS
    }

    @Test func tabKey() {
        let result = KeyEncoder.encode(input(keyCode: 48), options: normalOpts)
        #expect(result == Data([0x09]))
    }

    @Test func shiftTab() {
        // Shift+Tab → ESC[Z (backtab)
        let result = KeyEncoder.encode(
            input(keyCode: 48, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x5A]))
    }

    @Test func ctrlTab() {
        // Ctrl+Tab → ESC[9;5u (CSI u encoding, mod = 1 + 4 = 5)
        let result = KeyEncoder.encode(
            input(keyCode: 48, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x39, 0x3B, 0x35, 0x75]))
    }

    @Test func shiftReturn() {
        // Shift+Enter → ESC[13;2u (CSI u encoding, mod = 1 + 1 = 2)
        let result = KeyEncoder.encode(
            input(keyCode: 36, shift: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]))
    }

    @Test func ctrlReturn() {
        // Ctrl+Enter → ESC[13;5u (CSI u encoding, mod = 1 + 4 = 5)
        let result = KeyEncoder.encode(
            input(keyCode: 36, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x35, 0x75]))
    }

    @Test func altReturn() {
        // Alt+Enter → ESC[13;3u (CSI u encoding, mod = 1 + 2 = 3)
        let result = KeyEncoder.encode(
            input(keyCode: 36, option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x33, 0x75]))
    }

    @Test func escapeKey() {
        let result = KeyEncoder.encode(input(keyCode: 53), options: normalOpts)
        #expect(result == Data([0x1B]))
    }

    // MARK: - Ctrl + Character

    @Test func ctrlA() {
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a", control: true),
            options: normalOpts
        )
        #expect(result == Data([0x01]))
    }

    @Test func ctrlZ() {
        let result = KeyEncoder.encode(
            input(keyCode: 6, characters: "z", control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1A]))
    }

    @Test func ctrlShiftA() {
        // Ctrl+Shift+A → same control code as Ctrl+A
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "A",
                  charactersIgnoringModifiers: "A",
                  shift: true, control: true),
            options: normalOpts
        )
        #expect(result == Data([0x01]))
    }

    @Test func ctrlOpenBracket() {
        // Ctrl+[ → ESC
        let result = KeyEncoder.encode(
            input(keyCode: 33, characters: "[",
                  charactersIgnoringModifiers: "[",
                  control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B]))
    }

    @Test func ctrlCloseBracket() {
        // Ctrl+] → GS (0x1D)
        let result = KeyEncoder.encode(
            input(keyCode: 30, characters: "]",
                  charactersIgnoringModifiers: "]",
                  control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1D]))
    }

    @Test func ctrlBackslash() {
        // Ctrl+\ → FS (0x1C)
        let result = KeyEncoder.encode(
            input(keyCode: 42, characters: "\\",
                  charactersIgnoringModifiers: "\\",
                  control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1C]))
    }

    @Test func ctrlSlash() {
        // Ctrl+/ → US (0x1F)
        let result = KeyEncoder.encode(
            input(keyCode: 44, characters: "/",
                  charactersIgnoringModifiers: "/",
                  control: true),
            options: normalOpts
        )
        #expect(result == Data([0x1F]))
    }

    @Test func ctrlSpace() {
        // Ctrl+Space → NUL (0x00)
        let result = KeyEncoder.encode(
            input(keyCode: 49, characters: " ",
                  charactersIgnoringModifiers: " ",
                  control: true),
            options: normalOpts
        )
        #expect(result == Data([0x00]))
    }

    @Test func altCtrlA() {
        // Alt+Ctrl+A → ESC + 0x01
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a",
                  charactersIgnoringModifiers: "a",
                  control: true, option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x01]))
    }

    // MARK: - Alt + Character

    @Test func altB() {
        // Alt+B → ESC + 'b'
        let result = KeyEncoder.encode(
            input(keyCode: 11, characters: "∫",
                  charactersIgnoringModifiers: "b",
                  option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x62]))
    }

    @Test func altF() {
        // Alt+F → ESC + 'f'
        let result = KeyEncoder.encode(
            input(keyCode: 3, characters: "ƒ",
                  charactersIgnoringModifiers: "f",
                  option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x66]))
    }

    @Test func altD() {
        // Alt+D → ESC + 'd'
        let result = KeyEncoder.encode(
            input(keyCode: 2, characters: "∂",
                  charactersIgnoringModifiers: "d",
                  option: true),
            options: normalOpts
        )
        #expect(result == Data([0x1B, 0x64]))
    }

    // MARK: - Plain Characters

    @Test func plainCharacter() {
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a"),
            options: normalOpts
        )
        #expect(result == Data([0x61]))
    }

    @Test func plainUnicode() {
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "你"),
            options: normalOpts
        )
        #expect(result == "你".data(using: .utf8))
    }

    @Test func emptyCharactersReturnsNil() {
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: nil),
            options: normalOpts
        )
        #expect(result == nil)
    }

    // MARK: - Modifier Parameter

    @Test func modifierParamNoMods() {
        let i = input()
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: true) == 1)
    }

    @Test func modifierParamShift() {
        let i = input(shift: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: true) == 2)
    }

    @Test func modifierParamAlt() {
        let i = input(option: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: true) == 3)
    }

    @Test func modifierParamCtrl() {
        let i = input(control: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: true) == 5)
    }

    @Test func modifierParamShiftAltCtrl() {
        let i = input(shift: true, control: true, option: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: true) == 8)
    }

    @Test func modifierParamOptionAsAltOff() {
        let i = input(option: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: false) == 1)
    }

    @Test func modifierParamShiftCtrlOptionAsAltOff() {
        let i = input(shift: true, control: true, option: true)
        #expect(KeyEncoder.modifierParam(i, optionAsAlt: false) == 6)
    }

    // MARK: - optionAsAlt = false

    @Test func optionAsAltOff_altCharReturnsNil() {
        // Option+B with optionAsAlt off → nil (let macOS produce ∫)
        let result = KeyEncoder.encode(
            input(keyCode: 11, characters: "∫",
                  charactersIgnoringModifiers: "b",
                  option: true),
            options: noAltOpts
        )
        #expect(result == nil)
    }

    @Test func optionAsAltOff_altBackspaceIsPlainBackspace() {
        // Option+Backspace with optionAsAlt off → plain backspace (0x7F)
        let result = KeyEncoder.encode(
            input(keyCode: 51, option: true),
            options: noAltOpts
        )
        #expect(result == Data([0x7F]))
    }

    @Test func optionAsAltOff_altArrowSendsPlainArrow() {
        // Option+Up with optionAsAlt off → ESC[A (no Alt modifier)
        let result = KeyEncoder.encode(
            input(keyCode: 126, option: true),
            options: noAltOpts
        )
        #expect(result == Data([0x1B, 0x5B, 0x41]))
    }

    @Test func optionAsAltOff_ctrlOptionSendsCtrlOnly() {
        // Ctrl+Option+A with optionAsAlt off → 0x01 (no ESC prefix)
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a",
                  charactersIgnoringModifiers: "a",
                  control: true, option: true),
            options: noAltOpts
        )
        #expect(result == Data([0x01]))
    }

    @Test func optionAsAltOff_plainCharUnaffected() {
        // Plain 'a' without Option → works normally
        let result = KeyEncoder.encode(
            input(keyCode: 0, characters: "a"),
            options: noAltOpts
        )
        #expect(result == Data([0x61]))
    }
}
