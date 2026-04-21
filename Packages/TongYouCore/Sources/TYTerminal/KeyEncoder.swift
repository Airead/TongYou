import Foundation

/// Pure keyboard-to-terminal-sequence encoder.
///
/// Translates a `KeyInput` (an abstraction over NSEvent) into the bytes
/// that should be written to the PTY. Supports:
/// - xterm PC-style modifier encoding for special keys
/// - Alt (Option) as ESC prefix
/// - Ctrl + character control codes
/// - Application cursor mode (DECCKM)
///
/// Reference: Ghostty `src/input/function_keys.zig`, `src/input/key_encode.zig`.
public struct KeyEncoder: Sendable {

    /// Abstraction of a key event, decoupled from NSEvent for testability.
    public struct KeyInput: Sendable {
        public let keyCode: UInt16
        /// Characters produced by the key event (reflects shift, etc.).
        public let characters: String?
        /// Characters without modifier influence (for Alt-as-ESC).
        public let charactersIgnoringModifiers: String?
        public let shift: Bool
        public let control: Bool
        public let option: Bool
        public let command: Bool

        public init(
            keyCode: UInt16,
            characters: String?,
            charactersIgnoringModifiers: String?,
            shift: Bool,
            control: Bool,
            option: Bool,
            command: Bool
        ) {
            self.keyCode = keyCode
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers
            self.shift = shift
            self.control = control
            self.option = option
            self.command = command
        }
    }

    public struct Options: Sendable {
        public let appCursorMode: Bool
        public let optionAsAlt: Bool
        public let keypadApplication: Bool

        public init(appCursorMode: Bool, optionAsAlt: Bool, keypadApplication: Bool = false) {
            self.appCursorMode = appCursorMode
            self.optionAsAlt = optionAsAlt
            self.keypadApplication = keypadApplication
        }
    }

    // MARK: - Public

    /// Encode a key input into the byte sequence to write to the PTY.
    /// Returns nil if the event should not be sent (e.g., Cmd-only combos).
    ///
    /// When `options.optionAsAlt` is false and the Option key is held without
    /// Ctrl, character keys return nil so the macOS text input system can
    /// handle them (producing special characters like ™, ©, ñ, etc.).
    /// Special keys (arrows, function keys, etc.) still work but without
    /// the Alt modifier in the xterm parameter.
    public static func encode(_ input: KeyInput, options: Options) -> Data? {
        // Cmd combos are handled by the view layer, not sent to PTY.
        if input.command { return nil }

        let optionAsAlt = options.optionAsAlt
        let modParam = modifierParam(input, optionAsAlt: optionAsAlt)

        // Try special key encoding first (arrows, function keys, etc.).
        if let data = encodeSpecialKey(input, modParam: modParam, options: options) {
            return data
        }

        // Ctrl + character → control code, optionally with ESC prefix if Alt.
        if input.control {
            return encodeCtrlKey(input, optionAsAlt: optionAsAlt)
        }

        // When optionAsAlt is off and Option is held (without Ctrl),
        // return nil to let macOS handle native character input.
        if input.option && !optionAsAlt {
            return nil
        }

        // Alt + character → ESC prefix + character.
        if input.option {
            return encodeAltKey(input)
        }

        // Plain character → UTF-8.
        guard let chars = input.characters, !chars.isEmpty else {
            return nil
        }
        return chars.data(using: .utf8)
    }

    // MARK: - Modifier Parameter

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    /// Returns 1 when no modifiers are held (base case).
    public static func modifierParam(_ input: KeyInput, optionAsAlt: Bool) -> Int {
        var mod = 1
        if input.shift   { mod += 1 }
        if input.option && optionAsAlt { mod += 2 }
        if input.control { mod += 4 }
        return mod
    }

    // MARK: - Special Key Encoding

    // F1-F4 use a special encoding: base uses ESC O {P,Q,R,S},
    // but with modifiers they become ESC[1;{mod}P etc. (except F3).
    // F3 with modifier uses ESC[13;{mod}~ instead of ESC[1;{mod}R.
    private struct FunctionKeyEntry {
        let number: Int      // For modified: ESC[{number};{mod}~ or ESC[1;{mod}{final}
        let finalChar: UInt8 // For modified: final char (0 = use tilde)
        let baseSequence: Data

        /// F1-F4 style: base is ESC O {final}, modified is ESC[1;{mod}{final}.
        static func ss3(_ final: UInt8) -> FunctionKeyEntry {
            FunctionKeyEntry(
                number: 1, finalChar: final,
                baseSequence: Data([0x1B, 0x4F, final])
            )
        }

        /// F3 is special: modified uses ESC[13;{mod}~.
        static func f3() -> FunctionKeyEntry {
            FunctionKeyEntry(
                number: 13, finalChar: 0,
                baseSequence: Data([0x1B, 0x4F, 0x52])
            )
        }

        /// F5-F12 style: base is ESC[{n}~, modified is ESC[{n};{mod}~.
        static func tilde(_ number: Int) -> FunctionKeyEntry {
            var base: [UInt8] = [0x1B, 0x5B]
            for byte in "\(number)".utf8 { base.append(byte) }
            base.append(0x7E)
            return FunctionKeyEntry(number: number, finalChar: 0, baseSequence: Data(base))
        }
    }

    /// Arrow key table: keyCode → (finalChar, normalBase, appBase).
    private static let arrowKeys: [UInt16: (UInt8, Data, Data)] = [
        126: (0x41, Data([0x1B, 0x5B, 0x41]), Data([0x1B, 0x4F, 0x41])), // Up
        125: (0x42, Data([0x1B, 0x5B, 0x42]), Data([0x1B, 0x4F, 0x42])), // Down
        124: (0x43, Data([0x1B, 0x5B, 0x43]), Data([0x1B, 0x4F, 0x43])), // Right
        123: (0x44, Data([0x1B, 0x5B, 0x44]), Data([0x1B, 0x4F, 0x44])), // Left
    ]

    /// Navigation key table: keyCode → (number, finalChar).
    /// number=0 means final-char style (ESC[{final}), else tilde style (ESC[{n}~).
    private static let navKeys: [UInt16: (Int, UInt8)] = [
        115: (0, 0x48),  // Home   → ESC[H  / ESC[1;{mod}H
        119: (0, 0x46),  // End    → ESC[F  / ESC[1;{mod}F
        114: (2, 0x7E),  // Insert → ESC[2~ / ESC[2;{mod}~
        117: (3, 0x7E),  // Delete → ESC[3~ / ESC[3;{mod}~
        116: (5, 0x7E),  // PageUp → ESC[5~ / ESC[5;{mod}~
        121: (6, 0x7E),  // PageDn → ESC[6~ / ESC[6;{mod}~
    ]

    /// Function key table: keyCode → FunctionKeyEntry.
    private static let functionKeys: [UInt16: FunctionKeyEntry] = [
        122: .ss3(0x50),   // F1  → ESCOP  / ESC[1;{mod}P
        120: .ss3(0x51),   // F2  → ESCOQ  / ESC[1;{mod}Q
        99:  .f3(),        // F3  → ESCOR  / ESC[13;{mod}~
        118: .ss3(0x53),   // F4  → ESCOS  / ESC[1;{mod}S
        96:  .tilde(15),   // F5  → ESC[15~
        97:  .tilde(17),   // F6  → ESC[17~
        98:  .tilde(18),   // F7  → ESC[18~
        100: .tilde(19),   // F8  → ESC[19~
        101: .tilde(20),   // F9  → ESC[20~
        109: .tilde(21),   // F10 → ESC[21~
        103: .tilde(23),   // F11 → ESC[23~
        111: .tilde(24),   // F12 → ESC[24~
    ]

    private static func encodeSpecialKey(
        _ input: KeyInput, modParam: Int, options: Options
    ) -> Data? {
        let hasModifier = modParam > 1

        // Arrow keys
        if let arrow = arrowKeys[input.keyCode] {
            let (finalChar, normalBase, appBase) = arrow
            if hasModifier {
                return formatCSI(param1: 1, modParam: modParam, final: finalChar)
            }
            return options.appCursorMode ? appBase : normalBase
        }

        // Navigation keys (Home, End, Insert, Delete, PageUp, PageDown)
        if let nav = navKeys[input.keyCode] {
            let (number, finalChar) = nav
            if hasModifier {
                if number == 0 {
                    // Home/End: ESC[1;{mod}{final}
                    return formatCSI(param1: 1, modParam: modParam, final: finalChar)
                } else {
                    // Tilde keys: ESC[{n};{mod}~
                    return formatCSI(param1: number, modParam: modParam, final: 0x7E)
                }
            }
            // Base sequence
            if number == 0 {
                return Data([0x1B, 0x5B, finalChar])
            } else {
                var seq: [UInt8] = [0x1B, 0x5B]
                for byte in "\(number)".utf8 { seq.append(byte) }
                seq.append(0x7E)
                return Data(seq)
            }
        }

        // Function keys
        if let fk = functionKeys[input.keyCode] {
            if hasModifier {
                if fk.finalChar != 0 {
                    // F1/F2/F4: ESC[1;{mod}{final}
                    return formatCSI(param1: fk.number, modParam: modParam, final: fk.finalChar)
                } else {
                    // F3, F5-F12: ESC[{n};{mod}~
                    return formatCSI(param1: fk.number, modParam: modParam, final: 0x7E)
                }
            }
            return fk.baseSequence
        }

        // Return, Backspace, Tab, Escape — handle modifier combinations.
        switch input.keyCode {
        case 36: // Return
            if hasModifier {
                // CSI u encoding: ESC[13;{mod}u
                return formatCSI(param1: 13, modParam: modParam, final: 0x75)
            }
            return dataReturn
        case 51:
            if input.option && options.optionAsAlt { return Data([0x1B, 0x7F]) } // Alt+Backspace
            if input.control { return Data([0x08]) }       // Ctrl+Backspace → BS
            return dataBackspace
        case 48: // Tab
            if input.shift && !input.control && !input.option {
                // Shift+Tab → ESC[Z (backtab, universally supported)
                return dataBacktab
            }
            if hasModifier {
                // Other modifier combos: CSI u encoding ESC[9;{mod}u
                return formatCSI(param1: 9, modParam: modParam, final: 0x75)
            }
            return dataTab
        case 53: return dataEscape
        default: return nil
        }
    }

    /// Format: ESC[ {param1} ; {modParam} {final}
    private static func formatCSI(param1: Int, modParam: Int, final: UInt8) -> Data {
        var seq: [UInt8] = [0x1B, 0x5B]
        for byte in "\(param1)".utf8 { seq.append(byte) }
        seq.append(0x3B) // ';'
        for byte in "\(modParam)".utf8 { seq.append(byte) }
        seq.append(final)
        return Data(seq)
    }

    // MARK: - Ctrl Key Encoding

    private static func encodeCtrlKey(_ input: KeyInput, optionAsAlt: Bool) -> Data? {
        // Use charactersIgnoringModifiers to get the base key without Ctrl influence.
        guard let chars = input.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        let ctrlCode: UInt8? = switch value {
        // a-z → 0x01-0x1A
        case 0x61...0x7A: UInt8(value - 0x60)
        // A-Z → 0x01-0x1A (Shift+Ctrl)
        case 0x41...0x5A: UInt8(value - 0x40)
        // Special Ctrl combos
        case 0x5B: 0x1B       // Ctrl+[ → ESC
        case 0x5D: 0x1D       // Ctrl+] → GS
        case 0x5C: 0x1C       // Ctrl+\ → FS
        case 0x5E: 0x1E       // Ctrl+^ → RS
        case 0x5F: 0x1F       // Ctrl+_ → US
        case 0x40: 0x00       // Ctrl+@ → NUL
        case 0x20: 0x00       // Ctrl+Space → NUL
        case 0x2F: 0x1F       // Ctrl+/ → US
        default: nil
        }

        guard let code = ctrlCode else { return nil }

        // Alt+Ctrl → ESC prefix + control code (only when optionAsAlt is on)
        if input.option && optionAsAlt {
            return Data([0x1B, code])
        }
        return Data([code])
    }

    // MARK: - Alt Key Encoding

    private static func encodeAltKey(_ input: KeyInput) -> Data? {
        // Use the base character (without Option) to avoid macOS special chars.
        guard let chars = input.charactersIgnoringModifiers,
              let charData = chars.data(using: .utf8),
              !charData.isEmpty else {
            return nil
        }
        var result = Data([0x1B])
        result.append(charData)
        return result
    }

    // MARK: - Static Constants

    private static let dataReturn    = Data([0x0D])
    private static let dataBackspace = Data([0x7F])
    private static let dataTab       = Data([0x09])
    private static let dataBacktab   = Data([0x1B, 0x5B, 0x5A])  // ESC[Z
    private static let dataEscape    = Data([0x1B])
}
