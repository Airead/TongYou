/// DEC private mode flags for DECSET/DECRST.
///
/// Stores boolean modes as a UInt32 bitfield, and mouse tracking/format
/// modes as separate enums (since tracking modes are mutually exclusive).
/// Value type for snapshot passing.
/// Reference: Ghostty `src/terminal/modes.zig`.
struct TerminalModes: Equatable {
    private var flags: UInt32

    /// Mouse tracking mode (mutually exclusive).
    private(set) var mouseTracking: MouseTrackingMode = .none
    /// Mouse encoding format.
    private(set) var mouseFormat: MouseFormat = .x10

    init() {
        var f: UInt32 = 0
        // Defaults: cursor visible, autowrap on
        f |= Self.bit(.cursorVisible)
        f |= Self.bit(.autowrap)
        self.flags = f
    }

    // MARK: - Mode Definitions

    enum Mode: UInt16 {
        /// Application cursor keys (DECCKM). Off = normal, On = application.
        case cursorKeys = 1
        /// Auto-wrap mode (DECAWM). On = wrap at right margin.
        case autowrap = 7
        /// Cursor visible (DECTCEM). On = visible.
        case cursorVisible = 25
        /// Alternate screen buffer + save cursor + clear (mode 1049).
        case altScreen = 1049
        /// Bracketed paste mode (mode 2004).
        case bracketedPaste = 2004
    }

    /// Mouse tracking modes — mutually exclusive (setting one clears others).
    enum MouseTrackingMode: UInt8, Equatable {
        /// No mouse tracking.
        case none = 0
        /// X10 compatibility mode (DECSET 9): report button press only.
        case x10 = 9
        /// Normal tracking (DECSET 1000): report press and release.
        case normal = 100  // rawValue doesn't matter, stored as enum
        /// Button-event tracking (DECSET 1002): press/release + motion while button held.
        case button = 102
        /// Any-event tracking (DECSET 1003): press/release + all motion.
        case any = 103
    }

    /// Mouse encoding format — independent of tracking mode.
    enum MouseFormat: UInt8, Equatable {
        /// X10 format: ESC[M + 3 bytes. Coordinates limited to 223.
        case x10 = 0
        /// SGR format (DECSET 1006): ESC[<btn;x;y;M/m. No coordinate limit.
        case sgr = 6
    }

    // MARK: - Access

    func isSet(_ mode: Mode) -> Bool {
        flags & Self.bit(mode) != 0
    }

    mutating func set(_ mode: Mode, _ value: Bool) {
        if value {
            flags |= Self.bit(mode)
        } else {
            flags &= ~Self.bit(mode)
        }
    }

    /// Set mouse tracking mode from a raw DECSET/DECRST parameter.
    /// Returns true if the parameter was a recognized mouse tracking mode.
    @discardableResult
    mutating func setMouseTracking(rawParam: UInt16, enabled: Bool) -> Bool {
        let mode: MouseTrackingMode? = switch rawParam {
        case 9:    .x10
        case 1000: .normal
        case 1002: .button
        case 1003: .any
        default:   nil
        }
        guard let mode else { return false }
        if enabled {
            mouseTracking = mode
        } else if mouseTracking == mode {
            mouseTracking = .none
        }
        return true
    }

    /// Set mouse format from a raw DECSET/DECRST parameter.
    /// Returns true if the parameter was a recognized mouse format mode.
    @discardableResult
    mutating func setMouseFormat(rawParam: UInt16, enabled: Bool) -> Bool {
        switch rawParam {
        case 1006:
            mouseFormat = enabled ? .sgr : .x10
            return true
        default:
            return false
        }
    }

    mutating func reset() {
        self = TerminalModes()
    }

    // MARK: - Private

    /// Map mode enum to a bit position. Uses a fixed mapping to avoid
    /// depending on rawValue (which can be large numbers like 2004).
    private static func bit(_ mode: Mode) -> UInt32 {
        switch mode {
        case .cursorKeys:     return 1 << 0
        case .autowrap:       return 1 << 1
        case .cursorVisible:  return 1 << 2
        case .altScreen:      return 1 << 3
        case .bracketedPaste: return 1 << 4
        }
    }

    /// Convert a raw DECSET/DECRST parameter number to a Mode, if supported.
    static func from(rawValue: UInt16) -> Mode? {
        Mode(rawValue: rawValue)
    }
}
