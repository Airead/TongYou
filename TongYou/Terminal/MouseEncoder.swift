import Foundation

/// Encodes mouse events into terminal escape sequences.
///
/// Supports X10 and SGR encoding formats, with proper button codes,
/// modifier bits, and motion deduplication.
///
/// Reference: Ghostty `src/input/mouse_encode.zig`.
struct MouseEncoder {

    /// Mouse button identifiers.
    enum Button: UInt8 {
        case left = 0
        case middle = 1
        case right = 2
        case scrollUp = 64
        case scrollDown = 65
    }

    /// Mouse event action.
    enum Action {
        case press
        case release
        case motion
    }

    /// Modifier keys held during a mouse event.
    struct Modifiers {
        var shift: Bool = false
        var option: Bool = false   // Alt
        var control: Bool = false
    }

    /// A mouse event to encode.
    struct Event {
        var action: Action
        var button: Button?
        var col: Int         // 0-based grid column
        var row: Int         // 0-based grid row
        var modifiers: Modifiers = Modifiers()
    }

    /// Encode a mouse event according to the given tracking mode and format.
    /// Returns nil if the event should not be reported.
    static func encode(
        event: Event,
        trackingMode: TerminalModes.MouseTrackingMode,
        format: TerminalModes.MouseFormat
    ) -> Data? {
        guard shouldReport(event: event, mode: trackingMode) else { return nil }

        let buttonCode = self.buttonCode(event: event, format: format)

        switch format {
        case .x10:
            return encodeX10(buttonCode: buttonCode, col: event.col, row: event.row)
        case .sgr:
            return encodeSGR(
                buttonCode: buttonCode, col: event.col, row: event.row,
                isRelease: event.action == .release
            )
        }
    }

    // MARK: - Reporting Decision

    private static func shouldReport(
        event: Event,
        mode: TerminalModes.MouseTrackingMode
    ) -> Bool {
        switch mode {
        case .none:
            return false
        case .x10:
            // X10: only button presses of left, middle, right
            return event.action == .press && event.button != nil
                && (event.button == .left || event.button == .middle || event.button == .right)
        case .normal:
            // Normal: press and release, no motion
            return event.action != .motion
        case .button:
            // Button mode: press/release always; motion only if a button is held
            return event.button != nil
        case .any:
            // Any: everything
            return true
        }
    }

    // MARK: - Button Code

    private static func buttonCode(
        event: Event,
        format: TerminalModes.MouseFormat
    ) -> UInt8 {
        var code: UInt8

        if let button = event.button {
            if event.action == .release && format != .sgr {
                // Legacy formats encode all releases as button 3
                code = 3
            } else {
                code = button.rawValue
            }
        } else {
            // No button (motion with no pressed button)
            code = 3
        }

        // Modifier bits (not added for X10 tracking, but we handle
        // that at the shouldReport level — X10 only reports presses).
        if event.modifiers.shift   { code += 4 }
        if event.modifiers.option  { code += 8 }
        if event.modifiers.control { code += 16 }

        // Motion adds bit 5
        if event.action == .motion { code += 32 }

        return code
    }

    // MARK: - X10 Format

    private static func encodeX10(buttonCode: UInt8, col: Int, row: Int) -> Data? {
        // X10 can only encode coordinates up to 222 (stored as byte + 33)
        guard col <= 222, row <= 222 else { return nil }

        return Data([
            0x1B, 0x5B, 0x4D,           // ESC[M
            32 + buttonCode,
            UInt8(clamping: 32 + col + 1),
            UInt8(clamping: 32 + row + 1),
        ])
    }

    // MARK: - SGR Format

    private static func encodeSGR(
        buttonCode: UInt8, col: Int, row: Int, isRelease: Bool
    ) -> Data {
        // ESC[<btn;col;rowM (press) or ESC[<btn;col;rowm (release)
        let final: UInt8 = isRelease ? 0x6D : 0x4D  // 'm' or 'M'
        let str = "\u{1B}[<\(buttonCode);\(col + 1);\(row + 1)"
        var data = Data(str.utf8)
        data.append(final)
        return data
    }
}
