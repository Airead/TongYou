import Foundation
import TYTerminal

/// Parser for automation key specifications like `Ctrl+C`, `Alt+Left`, or `Enter`.
///
/// Produces a `KeyEncoder.KeyInput` that can be fed straight into
/// `KeyEncoder.encode(_:options:)` to generate the bytes written to a PTY.
///
/// Grammar (case-insensitive):
///   spec       := modifier ('+' modifier)* '+' base   |   base
///   modifier   := 'Ctrl' | 'Cmd' | 'Alt' | 'Opt' | 'Shift'
///   base       := named-key | single-char
///   named-key  := 'Enter' | 'Return' | 'Tab' | 'Escape' | 'Esc' | 'Space'
///               | 'Backspace' | 'Delete' | 'ForwardDelete'
///               | 'Up' | 'Down' | 'Left' | 'Right'
///               | 'Home' | 'End' | 'PageUp' | 'PageDown' | 'Insert'
///               | 'F1' ... 'F12'
///
/// Whitespace around '+' is tolerated. A duplicated modifier or an unknown
/// token raises `AutomationError.invalidParams`.
public enum AutomationKeySpec {

    /// Parse a key spec string into a `KeyEncoder.KeyInput` ready for `encode(_:options:)`.
    /// Throws `AutomationError.invalidParams` on malformed input.
    public static func parse(_ raw: String) throws -> KeyEncoder.KeyInput {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw AutomationError.invalidParams("key spec is empty")
        }

        // Split on '+' but keep empty tokens so a trailing '+' becomes an error.
        let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard !tokens.contains(where: { $0.isEmpty }) else {
            throw AutomationError.invalidParams("key spec has empty segment: '\(raw)'")
        }

        var shift = false
        var control = false
        var option = false
        var command = false

        for modToken in tokens.dropLast() {
            switch modToken.lowercased() {
            case "ctrl", "control":
                if control { throw AutomationError.invalidParams("duplicate modifier 'Ctrl' in '\(raw)'") }
                control = true
            case "cmd", "command":
                if command { throw AutomationError.invalidParams("duplicate modifier 'Cmd' in '\(raw)'") }
                command = true
            case "alt", "opt", "option":
                if option { throw AutomationError.invalidParams("duplicate modifier 'Alt' in '\(raw)'") }
                option = true
            case "shift":
                if shift { throw AutomationError.invalidParams("duplicate modifier 'Shift' in '\(raw)'") }
                shift = true
            default:
                throw AutomationError.invalidParams("unknown modifier '\(modToken)' in '\(raw)'")
            }
        }

        let base = tokens.last!

        if let entry = namedKey(base) {
            return KeyEncoder.KeyInput(
                keyCode: entry.keyCode,
                characters: entry.characters,
                charactersIgnoringModifiers: entry.characters,
                shift: shift,
                control: control,
                option: option,
                command: command
            )
        }

        if let charInput = characterKey(base, shift: shift, control: control, option: option, command: command) {
            return charInput
        }

        throw AutomationError.invalidParams("unknown key '\(base)' in '\(raw)'")
    }

    // MARK: - Named keys

    /// keyCode values match Apple's virtual key codes used by `NSEvent.keyCode`,
    /// so the produced `KeyInput` is indistinguishable (to the encoder) from a
    /// real keyboard event.
    private struct NamedKey {
        let keyCode: UInt16
        let characters: String?
    }

    private static func namedKey(_ token: String) -> NamedKey? {
        let lower = token.lowercased()

        // Function keys: F1..F12.
        if lower.hasPrefix("f"), let n = UInt8(lower.dropFirst()), (1...12).contains(n) {
            let keyCode: UInt16
            switch n {
            case 1:  keyCode = 122
            case 2:  keyCode = 120
            case 3:  keyCode = 99
            case 4:  keyCode = 118
            case 5:  keyCode = 96
            case 6:  keyCode = 97
            case 7:  keyCode = 98
            case 8:  keyCode = 100
            case 9:  keyCode = 101
            case 10: keyCode = 109
            case 11: keyCode = 103
            case 12: keyCode = 111
            default: return nil
            }
            return NamedKey(keyCode: keyCode, characters: nil)
        }

        switch lower {
        case "enter", "return":   return NamedKey(keyCode: 36,  characters: "\r")
        case "tab":               return NamedKey(keyCode: 48,  characters: "\t")
        case "escape", "esc":     return NamedKey(keyCode: 53,  characters: "\u{1B}")
        case "space":             return NamedKey(keyCode: 49,  characters: " ")
        case "backspace":         return NamedKey(keyCode: 51,  characters: nil)
        case "delete", "forwarddelete":
                                  return NamedKey(keyCode: 117, characters: nil)
        case "up":                return NamedKey(keyCode: 126, characters: nil)
        case "down":              return NamedKey(keyCode: 125, characters: nil)
        case "left":              return NamedKey(keyCode: 123, characters: nil)
        case "right":             return NamedKey(keyCode: 124, characters: nil)
        case "home":              return NamedKey(keyCode: 115, characters: nil)
        case "end":               return NamedKey(keyCode: 119, characters: nil)
        case "pageup":            return NamedKey(keyCode: 116, characters: nil)
        case "pagedown":          return NamedKey(keyCode: 121, characters: nil)
        case "insert":            return NamedKey(keyCode: 114, characters: nil)
        default:                  return nil
        }
    }

    // MARK: - Character keys

    /// Build a `KeyInput` for a single character. The encoder keys off the
    /// characters fields for non-special keys, so keyCode can be a sentinel.
    /// Multi-character tokens are rejected — multi-char text should go through
    /// `pane.sendText`, not `pane.sendKey`.
    private static func characterKey(
        _ token: String,
        shift: Bool,
        control: Bool,
        option: Bool,
        command: Bool
    ) -> KeyEncoder.KeyInput? {
        guard token.unicodeScalars.count == 1 else { return nil }

        // The base character (without shift) goes into charactersIgnoringModifiers.
        // KeyEncoder's Ctrl path reads charactersIgnoringModifiers and expects
        // lowercase ASCII for alphabetic keys; the shifted form feeds `characters`.
        let base = token.lowercased()
        let visible = shift ? base.uppercased() : base

        return KeyEncoder.KeyInput(
            keyCode: 0xFFFF,
            characters: visible,
            charactersIgnoringModifiers: base,
            shift: shift,
            control: control,
            option: option,
            command: command
        )
    }
}
