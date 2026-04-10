import Foundation

/// Dispatches VTAction events to Screen operations.
///
/// Owns the SGR "pen" (current attributes), terminal modes, and saved cursor state.
/// Confined to ptyQueue alongside Screen.
///
/// Reference: Ghostty `src/terminal/stream.zig`.
struct StreamHandler {

    private let screen: Screen
    private(set) var modes = TerminalModes()
    private var currentAttributes = CellAttributes.default
    private var savedCursor: SavedCursorState?
    private var lastPrintedScalar: Unicode.Scalar?

    /// Callback: PTY write-back for device status reports.
    var onWriteBack: ((Data) -> Void)?
    /// Callback: window title changed.
    var onTitleChanged: ((String) -> Void)?
    /// Callback: BEL (0x07) received.
    var onBell: (() -> Void)?
    /// Callback: OSC 52 clipboard set request (decoded text).
    var onClipboardSet: ((String) -> Void)?

    init(screen: Screen) {
        self.screen = screen
    }

    // MARK: - Public

    mutating func handle(_ action: VTAction) {
        switch action {
        case .print(let scalar):
            lastPrintedScalar = scalar
            screen.write(scalar, attributes: currentAttributes)

        case .printBatch(let count, let buffer):
            screen.writeASCIIBatch(buffer, count: count, attributes: currentAttributes)
            // Track last printed scalar for REP command
            lastPrintedScalar = Unicode.Scalar(buffer[count - 1])

        case .execute(let byte):
            handleExecute(byte)

        case .csiDispatch(let params):
            handleCSI(params)

        case .escDispatch(let final, let imCount, _):
            if imCount == 0 {
                handleESC(final: final)
            }

        case .oscDispatch(let data):
            handleOSC(data)

        case .dcsHook, .dcsPut, .dcsUnhook,
             .apcStart, .apcPut, .apcEnd:
            break // Not handled in P3
        }
    }

    // MARK: - C0 Control Characters

    private func handleExecute(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: screen.backspace()
        case 0x09: screen.tab()
        case 0x0A, 0x0B, 0x0C: screen.lineFeed() // LF, VT, FF
        case 0x0D: screen.carriageReturn()
        default: break
        }
    }

    // MARK: - CSI Dispatch

    private mutating func handleCSI(_ params: CSIParams) {
        let final = params.finalByte
        let hasQuestion = params.hasIntermediate(0x3F) // '?'
        let hasSpace = params.hasIntermediate(0x20)    // ' '

        switch final {
        // --- Cursor Movement ---
        case 0x41: // 'A' - CUU (Cursor Up)
            screen.cursorUp(Int(params.param(0, default: 1)))

        case 0x42: // 'B' - CUD (Cursor Down)
            screen.cursorDown(Int(params.param(0, default: 1)))

        case 0x43: // 'C' - CUF (Cursor Forward)
            screen.cursorForward(Int(params.param(0, default: 1)))

        case 0x44: // 'D' - CUB (Cursor Backward)
            screen.cursorBackward(Int(params.param(0, default: 1)))

        case 0x45: // 'E' - CNL (Cursor Next Line)
            screen.cursorDown(Int(params.param(0, default: 1)))
            screen.carriageReturn()

        case 0x46: // 'F' - CPL (Cursor Previous Line)
            screen.cursorUp(Int(params.param(0, default: 1)))
            screen.carriageReturn()

        case 0x47: // 'G' - CHA (Cursor Horizontal Absolute)
            screen.setCursorCol(Int(params.param(0, default: 1)) - 1)

        case 0x48, 0x66: // 'H' or 'f' - CUP/HVP (Cursor Position)
            let row = Int(params.param(0, default: 1)) - 1
            let col = Int(params.param(1, default: 1)) - 1
            screen.setCursorPos(row: row, col: col)

        case 0x64: // 'd' - VPA (Vertical Position Absolute)
            screen.setCursorRow(Int(params.param(0, default: 1)) - 1)

        // --- Erase ---
        case 0x4A: // 'J' - ED (Erase in Display)
            screen.eraseDisplay(mode: Int(params.param(0, default: 0)), attributes: eraseAttributes)

        case 0x4B: // 'K' - EL (Erase in Line)
            screen.eraseLine(mode: Int(params.param(0, default: 0)), attributes: eraseAttributes)

        case 0x58: // 'X' - ECH (Erase Characters)
            screen.eraseCharacters(count: Int(params.param(0, default: 1)), attributes: eraseAttributes)

        // --- Scroll ---
        case 0x53: // 'S' - SU (Scroll Up)
            screen.scrollUp(count: Int(params.param(0, default: 1)))

        case 0x54: // 'T' - SD (Scroll Down)
            screen.scrollDown(count: Int(params.param(0, default: 1)))

        // --- Scroll Region / Modes ---
        case 0x72: // 'r' - DECSTBM (Set Top and Bottom Margins) or restore modes
            if hasQuestion {
                // Restore modes — not implemented in P3
            } else {
                let top = Int(params.param(0, default: 1)) - 1
                let bottom = Int(params.param(1, default: UInt16(screen.rows))) - 1
                screen.setScrollRegion(top: top, bottom: bottom)
            }

        // --- Insert / Delete ---
        case 0x40: // '@' - ICH (Insert Characters)
            screen.insertCharacters(count: Int(params.param(0, default: 1)))

        case 0x50: // 'P' - DCH (Delete Characters)
            screen.deleteCharacters(count: Int(params.param(0, default: 1)))

        case 0x4C: // 'L' - IL (Insert Lines)
            screen.insertLines(count: Int(params.param(0, default: 1)))

        case 0x4D: // 'M' - DL (Delete Lines)
            screen.deleteLines(count: Int(params.param(0, default: 1)))

        // --- Tab ---
        case 0x49: // 'I' - CHT (Cursor Horizontal Tabulation)
            screen.forwardTab(count: Int(params.param(0, default: 1)))

        case 0x5A: // 'Z' - CBT (Cursor Backward Tabulation)
            screen.backwardTab(count: Int(params.param(0, default: 1)))

        // --- SGR ---
        case 0x6D: // 'm' - SGR (Select Graphic Rendition)
            SGRParser.parse(params, into: &currentAttributes)

        // --- Modes ---
        case 0x68: // 'h' - SM (Set Mode)
            if hasQuestion {
                for i in 0..<params.count {
                    setDECMode(params[i], value: true)
                }
            }

        case 0x6C: // 'l' - RM (Reset Mode)
            if hasQuestion {
                for i in 0..<params.count {
                    setDECMode(params[i], value: false)
                }
            }

        // --- Device Status Report ---
        case 0x6E: // 'n' - DSR
            handleDSR(params)

        // --- Save / Restore Cursor ---
        case 0x73: // 's' - SCOSC (Save Cursor)
            if !hasQuestion {
                saveCursor()
            }

        case 0x75: // 'u' - SCORC (Restore Cursor)
            if !hasQuestion {
                restoreCursor()
            }

        // --- Repeat ---
        case 0x62: // 'b' - REP (Repeat Previous Character)
            if let scalar = lastPrintedScalar {
                let count = Int(params.param(0, default: 1))
                for _ in 0..<count {
                    screen.write(scalar, attributes: currentAttributes)
                }
            }

        // --- Cursor Style ---
        case 0x71: // 'q' - DECSCUSR (with space intermediate)
            if hasSpace {
                let style = params.param(0, default: 0)
                switch style {
                case 0, 1: screen.setCursorShape(.block)
                case 2: screen.setCursorShape(.block) // steady block
                case 3, 4: screen.setCursorShape(.underline)
                case 5, 6: screen.setCursorShape(.bar)
                default: break
                }
            }

        default:
            break
        }
    }

    // MARK: - ESC Dispatch

    private mutating func handleESC(final: UInt8) {
        switch final {
        case 0x37: // '7' - DECSC (Save Cursor)
            saveCursor()

        case 0x38: // '8' - DECRC (Restore Cursor)
            restoreCursor()

        case 0x44: // 'D' - IND (Index = line feed)
            screen.lineFeed()

        case 0x45: // 'E' - NEL (Next Line)
            screen.newline()

        case 0x4D: // 'M' - RI (Reverse Index)
            screen.reverseIndex()

        case 0x63: // 'c' - RIS (Full Reset)
            screen.fullReset()
            currentAttributes = .default
            modes.reset()
            savedCursor = nil

        default:
            break
        }
    }

    // MARK: - OSC Dispatch

    private func handleOSC(_ data: [UInt8]) {
        // Parse "number;string" format
        guard let separatorIdx = data.firstIndex(of: 0x3B) else { return }
        let numBytes = data[0..<separatorIdx]
        guard let numStr = String(bytes: numBytes, encoding: .utf8),
              let oscNum = Int(numStr) else { return }

        let stringData = data[(separatorIdx + 1)...]

        switch oscNum {
        case 0, 2: // Set window title
            if let title = String(bytes: stringData, encoding: .utf8) {
                onTitleChanged?(title)
            }
        case 52:
            handleOSC52(stringData)
        default:
            break
        }
    }

    // MARK: - OSC 52 (Clipboard)

    /// Handle OSC 52 clipboard operations.
    /// Format: `52 ; <selection> ; <base64-data>` where selection is typically "c" (clipboard).
    /// Query (`?`) is rejected to prevent unauthorized clipboard reads.
    private func handleOSC52(_ data: ArraySlice<UInt8>) {
        guard let sepIdx = data.firstIndex(of: 0x3B) else { return }
        let payload = data[(sepIdx + 1)...]
        guard !payload.isEmpty else { return }

        // Reject query ("?") to prevent unauthorized clipboard reads
        if payload.count == 1, payload.first == 0x3F { return }

        guard let b64String = String(bytes: payload, encoding: .ascii),
              let decoded = Data(base64Encoded: b64String),
              let text = String(data: decoded, encoding: .utf8),
              !text.isEmpty
        else { return }

        onClipboardSet?(text)
    }

    // MARK: - DEC Mode Set/Reset

    private mutating func setDECMode(_ rawParam: UInt16, value: Bool) {
        // Try mouse tracking modes first (9, 1000, 1002, 1003)
        if modes.setMouseTracking(rawParam: rawParam, enabled: value) { return }
        // Try mouse format modes (1006)
        if modes.setMouseFormat(rawParam: rawParam, enabled: value) { return }

        guard let mode = TerminalModes.from(rawValue: rawParam) else { return }

        modes.set(mode, value)

        // Side effects
        switch mode {
        case .cursorVisible:
            screen.setCursorVisible(value)
        case .altScreen:
            if value {
                saveCursor()
                screen.switchToAltScreen()
                screen.eraseDisplay(mode: 2, attributes: eraseAttributes)
            } else {
                screen.switchToMainScreen()
                restoreCursor()
            }
        default:
            break
        }
    }

    // MARK: - DSR (Device Status Report)

    private func handleDSR(_ params: CSIParams) {
        guard params.count >= 1 else { return }
        switch params[0] {
        case 6: // Report cursor position
            let row = screen.cursorRow + 1
            let col = screen.cursorCol + 1
            let response = "\u{1B}[\(row);\(col)R"
            onWriteBack?(Data(response.utf8))
        case 5: // Status report — report OK
            onWriteBack?(Data("\u{1B}[0n".utf8))
        default:
            break
        }
    }

    // MARK: - Cursor Save / Restore

    private mutating func saveCursor() {
        savedCursor = SavedCursorState(
            col: screen.cursorCol,
            row: screen.cursorRow,
            attributes: currentAttributes
        )
    }

    private mutating func restoreCursor() {
        guard let saved = savedCursor else { return }
        screen.setCursorPos(row: saved.row, col: saved.col)
        currentAttributes = saved.attributes
    }

    // MARK: - Private

    /// Attributes used for erase operations (keeps current bg color, clears everything else).
    private var eraseAttributes: CellAttributes {
        var attrs = CellAttributes.default
        attrs.bgColor = currentAttributes.bgColor
        return attrs
    }
}
