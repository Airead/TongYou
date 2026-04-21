/// DEC private mode flags for DECSET/DECRST.
///
/// Stores boolean modes as a UInt32 bitfield, and mouse tracking/format
/// modes as separate enums (since tracking modes are mutually exclusive).
/// Value type for snapshot passing.
/// Reference: Ghostty `src/terminal/modes.zig`.
public struct TerminalModes: Equatable, Sendable {
    private var flags: UInt32
    /// ANSI mode flags (separate from DEC private mode flags).
    private var ansiFlags: UInt8 = 0

    /// Mouse tracking mode (mutually exclusive).
    public private(set) var mouseTracking: MouseTrackingMode = .none
    /// Mouse encoding format.
    public private(set) var mouseFormat: MouseFormat = .x10

    public init() {
        var f: UInt32 = 0
        // Defaults: cursor visible, autowrap on
        f |= Self.bit(.cursorVisible)
        f |= Self.bit(.autowrap)
        self.flags = f
    }

    // MARK: - ANSI Mode Definitions

    /// ANSI modes (CSI h / CSI l without `?`).
    /// These use a separate bitfield from DEC private modes.
    public enum ANSIMode: UInt16, Sendable {
        /// Insert/Replace Mode (IRM). Set = insert mode, Reset = replace mode.
        /// In insert mode, writing a character shifts existing content right.
        case insert = 4
        /// Line Feed/New Line Mode (LNM). Set = LF acts as CRLF, Reset = LF only.
        /// When set, LF, VT, FF move cursor to first column after moving down.
        case newline = 20
    }

    // MARK: - DEC Private Mode Definitions

    public enum Mode: UInt16, Sendable {
        /// Application cursor keys (DECCKM). Off = normal, On = application.
        case cursorKeys = 1
        /// Column mode (DECCOLM). Set = 132 columns, Reset = 80 columns.
        case columnMode = 3
        /// Scrolling mode (DECSCLM). Set = smooth scroll, Reset = jump scroll.
        /// No-op on modern GPU-accelerated terminals (always instant).
        case smoothScroll = 4
        /// Screen mode (DECSCNM). Set = reverse video, Reset = normal.
        case reverseVideo = 5
        /// Origin mode (DECOM). Set = cursor positioning relative to scroll
        /// margins, Reset = absolute (top-left of screen).
        case originMode = 6
        /// Auto-wrap mode (DECAWM). On = wrap at right margin.
        case autowrap = 7
        /// Cursor visible (DECTCEM). On = visible.
        case cursorVisible = 25
        /// Focus event reporting (mode 1004). When enabled, the terminal
        /// writes `CSI I` / `CSI O` to the PTY on focus in / focus out.
        case focusEvents = 1004
        /// Alternate screen buffer + save cursor + clear (mode 1049).
        case altScreen = 1049
        /// Bracketed paste mode (mode 2004).
        case bracketedPaste = 2004
        /// Synchronized output (mode 2026). While active the terminal keeps
        /// processing escape sequences internally but holds snapshot
        /// delivery to the client until the app ends the update or the
        /// safety timeout elapses.
        case syncedUpdate = 2026
        /// Keypad application mode (DECKPAM, ESC =). On = application sequences.
        case keypadApplication = 9999
    }

    /// Mouse tracking modes — mutually exclusive (setting one clears others).
    public enum MouseTrackingMode: UInt8, Equatable, Sendable {
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
    public enum MouseFormat: UInt8, Equatable, Sendable {
        /// X10 format: ESC[M + 3 bytes. Coordinates limited to 223.
        case x10 = 0
        /// SGR format (DECSET 1006): ESC[<btn;x;y;M/m. No coordinate limit.
        case sgr = 6
    }

    // MARK: - Access

    public func isSet(_ mode: Mode) -> Bool {
        flags & Self.bit(mode) != 0
    }

    public mutating func set(_ mode: Mode, _ value: Bool) {
        if value {
            flags |= Self.bit(mode)
        } else {
            flags &= ~Self.bit(mode)
        }
    }

    /// Set mouse tracking mode from a raw DECSET/DECRST parameter.
    /// Returns true if the parameter was a recognized mouse tracking mode.
    @discardableResult
    public mutating func setMouseTracking(rawParam: UInt16, enabled: Bool) -> Bool {
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
    public mutating func setMouseFormat(rawParam: UInt16, enabled: Bool) -> Bool {
        switch rawParam {
        case 1006:
            mouseFormat = enabled ? .sgr : .x10
            return true
        default:
            return false
        }
    }

    // MARK: - ANSI Mode Access

    public func isSet(_ mode: ANSIMode) -> Bool {
        ansiFlags & Self.ansiBit(mode) != 0
    }

    public mutating func set(_ mode: ANSIMode, _ value: Bool) {
        if value {
            ansiFlags |= Self.ansiBit(mode)
        } else {
            ansiFlags &= ~Self.ansiBit(mode)
        }
    }

    public mutating func reset() {
        self = TerminalModes()
    }

    // MARK: - Private

    /// Map ANSI mode enum to a bit position.
    private static func ansiBit(_ mode: ANSIMode) -> UInt8 {
        switch mode {
        case .insert:  return 1 << 0
        case .newline: return 1 << 1
        }
    }

    /// Map DEC private mode enum to a bit position. Uses a fixed mapping to avoid
    /// depending on rawValue (which can be large numbers like 2004).
    private static func bit(_ mode: Mode) -> UInt32 {
        switch mode {
        case .cursorKeys:     return 1 << 0
        case .autowrap:       return 1 << 1
        case .cursorVisible:  return 1 << 2
        case .altScreen:      return 1 << 3
        case .bracketedPaste: return 1 << 4
        case .focusEvents:    return 1 << 5
        case .syncedUpdate:   return 1 << 6
        case .keypadApplication: return 1 << 7
        case .columnMode:     return 1 << 8
        case .smoothScroll:   return 1 << 9
        case .reverseVideo:   return 1 << 10
        case .originMode:     return 1 << 11
        }
    }

    /// Convert a raw DECSET/DECRST parameter number to a Mode, if supported.
    public static func from(rawValue: UInt16) -> Mode? {
        Mode(rawValue: rawValue)
    }

    /// Convert a raw ANSI SM/RM parameter number to an ANSIMode, if supported.
    public static func ansiFrom(rawValue: UInt16) -> ANSIMode? {
        ANSIMode(rawValue: rawValue)
    }
}
