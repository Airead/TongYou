import Foundation

/// Dispatches VTAction events to Screen operations.
///
/// Owns the SGR "pen" (current attributes), terminal modes, and saved cursor state.
/// Confined to ptyQueue alongside Screen.
///
/// Reference: Ghostty `src/terminal/stream.zig`.
public struct StreamHandler {

    private let screen: Screen
    public private(set) var modes = TerminalModes()
    private var currentAttributes = CellAttributes.default
    private var savedCursor: SavedCursorState?
    private var savedModes: TerminalModes?
    public let hyperlinkRegistry = HyperlinkRegistry()
    private var currentHyperlinkId: UInt16 = 0
    private var lastPrintedScalar: Unicode.Scalar?
    private var pendingString: String = ""

    public private(set) var currentTitle: String = ""
    private var titleStack: [String] = []
    private static let maxTitleStackDepth = 10
    private static let maxTitleLength = 1024

    /// Callback: PTY write-back for device status reports.
    public var onWriteBack: ((Data) -> Void)?
    /// Callback: text area pixel size query for CSI 14 t.
    public var onWindowPixelSizeRequest: (() -> (width: UInt32, height: UInt32))?
    /// Callback: window title changed.
    public var onTitleChanged: ((String) -> Void)?
    /// Callback: BEL (0x07) received.
    public var onBell: (() -> Void)?
    /// Callback: OSC 52 clipboard set request (decoded text).
    public var onClipboardSet: ((String) -> Void)?
    /// Callback: shell integration reported the running command (nil = shell prompt).
    public var onRunningCommandChanged: ((String?) -> Void)?
    /// Callback: pane notification triggered by OSC 9 / 777 / 1337 (title, body).
    public var onPaneNotification: ((String, String) -> Void)?
    /// Callback: focus event reporting (DECSET 1004) toggled on/off.
    public var onFocusReportingChanged: ((Bool) -> Void)?
    /// Callback: color scheme reporting (DECSET 2031) toggled on/off.
    public var onColorSchemeReportingChanged: ((Bool) -> Void)?
    /// Callback: query current system color scheme (dark = true, light = false).
    /// Used by DECRQM 2031 and DSR 996/997 responses.
    public var onColorSchemeQuery: (() -> Bool)?
    /// Callback: current working directory changed (OSC 7 file://URL).
    public var onWorkingDirectoryChanged: ((String) -> Void)?
    /// Callback: query dynamic color for OSC 10/11/17/19 etc.
    /// Parameter is the OSC number (10 = foreground, 11 = background, etc.).
    /// Return nil if the color is not available.
    public var onDynamicColorQuery: ((Int) -> RGBColor?)?
    /// Callback: dynamic color changed by OSC 10/11/17/19 etc.
    /// Parameters are (OSC number, new color).
    public var onDynamicColorSet: ((Int, RGBColor) -> Void)?
    /// Callback: dynamic color reset by OSC 110/111/112/117/119 etc.
    /// Parameter is the original OSC number (10, 11, 12, 17, 19).
    public var onDynamicColorReset: ((Int) -> Void)?
    /// Callback: pointer shape changed by OSC 22.
    /// Parameter is the cursor shape name (e.g. "default", "pointer", "text").
    public var onPointerShapeChanged: ((String) -> Void)?
    /// Callback: query palette color for OSC 4.
    /// Parameter is the palette index (0-255). Return nil if not available.
    public var onPaletteColorQuery: ((Int) -> RGBColor?)?
    /// Callback: palette color changed by OSC 4.
    /// Parameters are (palette index, new color).
    public var onPaletteColorSet: ((Int, RGBColor) -> Void)?
    /// Callback: unhandled control sequence or mode received (for debugging/telemetry).
    public var onUnhandledSequence: ((String) -> Void)?

    public init(screen: Screen) {
        self.screen = screen
    }

    // MARK: - Public

    public mutating func handle(_ action: VTAction) {
        if case .print = action {} else { flushPendingCluster() }

        switch action {
        case .print(let scalar):
            lastPrintedScalar = scalar
            appendScalarToCluster(scalar)

        case .printBatch(let count, let buffer):
            screen.writeASCIIBatch(buffer, count: count, attributes: currentAttributes)
            lastPrintedScalar = Unicode.Scalar(buffer[count - 1])

        case .execute(let byte):
            handleExecute(byte)

        case .csiDispatch(let params):
            handleCSI(params)

        case .escDispatch(let final, let imCount, let intermediates):
            if imCount == 0 {
                handleESC(final: final)
            } else if imCount == 1 {
                switch intermediates.0 {
                case 0x23: // '#'
                    handleESCLineSize(final: final)
                case 0x28, 0x29: // '(', ')'
                    handleESCCharset(final: final, intermediate: intermediates.0)
                case 0x25: // '%'
                    handleESCCharsetSelect(final: final)
                default:
                    onUnhandledSequence?("ESC \(String(Unicode.Scalar(intermediates.0)))\(String(Unicode.Scalar(final))) not implemented")
                }
            } else {
                onUnhandledSequence?("ESC with \(imCount) intermediates not implemented")
            }

        case .oscDispatch(let data):
            handleOSC(data)

        case .dcsHook, .dcsPut, .dcsUnhook:
            onUnhandledSequence?("DCS sequence (not implemented)")
        case .apcStart, .apcPut, .apcEnd:
            // APC sequences are silently ignored per design.
            break
        }
    }

    public mutating func flush() {
        flushPendingCluster()
    }

    private mutating func appendScalarToCluster(_ scalar: Unicode.Scalar) {
        if !modes.isSet(.graphemeClustering) {
            // Mode 2027 off: each scalar is an independent cell.
            screen.write(GraphemeCluster(scalar), attributes: currentAttributes)
            return
        }

        if pendingString.isEmpty {
            pendingString = String(scalar)
            return
        }

        let previousCount = pendingString.count
        pendingString.unicodeScalars.append(scalar)

        if pendingString.count == previousCount {
            return
        } else {
            let cluster = GraphemeCluster(scalars: Array(pendingString.dropLast().unicodeScalars))
            screen.write(cluster, attributes: currentAttributes)
            pendingString = String(scalar)
        }
    }

    private mutating func flushPendingCluster() {
        guard !pendingString.isEmpty else { return }
        if modes.isSet(.graphemeClustering) {
            let cluster = GraphemeCluster(scalars: Array(pendingString.unicodeScalars))
            screen.write(cluster, attributes: currentAttributes)
        } else {
            // Mode 2027 off: write each scalar independently.
            for scalar in pendingString.unicodeScalars {
                screen.write(GraphemeCluster(scalar), attributes: currentAttributes)
            }
        }
        pendingString = ""
    }

    // MARK: - C0 Control Characters

    private func handleExecute(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: screen.backspace()
        case 0x09: screen.tab()
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            // LNM mode: when enabled, LF acts as CRLF (newline)
            if modes.isSet(.newline) {
                screen.newline()
            } else {
                screen.lineFeed()
            }
        case 0x0D: screen.carriageReturn()
        case 0x0E: screen.charsetState.invokeGL(.g1) // SO - Shift Out
        case 0x0F: screen.charsetState.invokeGL(.g0) // SI - Shift In
        default:
            onUnhandledSequence?("C0 control character 0x\(String(byte, radix: 16, uppercase: true)) (not implemented)")
        }
    }

    // MARK: - CSI Dispatch

    private mutating func handleCSI(_ params: CSIParams) {
        let final = params.finalByte
        let hasQuestion = params.hasIntermediate(0x3F) // '?'
        let hasGreater = params.hasIntermediate(0x3E)  // '>'
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
        case 0x72: // 'r' - DECSTBM (Set Top and Bottom Margins) or DECRM (Restore Modes)
            if hasQuestion {
                restoreModes()
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
            if hasGreater {
                handleXTMODKEYS(params)
                break
            }
            SGRParser.parse(params, into: &currentAttributes)

        // --- Modes ---
        case 0x68: // 'h' - SM (Set Mode)
            if hasQuestion {
                for i in 0..<params.count {
                    setDECMode(params[i], value: true)
                }
            } else {
                for i in 0..<params.count {
                    setANSIMode(params[i], value: true)
                }
            }

        case 0x6C: // 'l' - RM (Reset Mode)
            if hasQuestion {
                for i in 0..<params.count {
                    setDECMode(params[i], value: false)
                }
            } else {
                for i in 0..<params.count {
                    setANSIMode(params[i], value: false)
                }
            }

        // --- Device Status Report ---
        case 0x6E: // 'n' - DSR
            handleDSR(params)

        case 0x63: // 'c' - DA1 (Send Device Attributes)
            // Both CSI c (or CSI 0 c) and CSI ? 0 c request primary device attributes.
            // Respond as a modern VT500-class terminal with color support.
            // 65 = VT500 series
            // 1  = 132-column mode
            // 9  = national replacement character sets (NRCS)
            // 12 = SCS (Select Character Set)
            // 18 = windowing capability
            // 22 = ANSI color support
            let response = "\u{1B}[?65;1;9;12;18;22c"
            onWriteBack?(Data(response.utf8))

        // --- Save / Restore Cursor ---
        case 0x73: // 's' - SCOSC (Save Cursor) or DECSM (Save Modes)
            if !hasQuestion {
                saveCursor()
            } else {
                saveModes()
            }

        case 0x75: // 'u' - SCORC (Restore Cursor) or DECRM (Restore Modes)
            if !hasQuestion {
                restoreCursor()
            } else {
                restoreModes()
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
                default:
                    onUnhandledSequence?("CSI SP q DECSCUSR style \(style) not implemented")
                }
            } else {
                // CSI Ps q without SP is DECLL (Load LEDs), a VT100-era
                // sequence for keyboard indicators.  Silently ignored.
                break
            }

        // --- DECRQM (Request Mode) ---
        case 0x70: // 'p' — DECRQM query (`CSI ? <mode> $ p`).
            // Only handled when both '?' (private) and '$' (intermediate) are
            // present; plain 'p' sequences are unused by us and silently dropped.
            if hasQuestion && params.hasIntermediate(0x24) {
                handleDECRQM(params)
            } else {
                onUnhandledSequence?("CSI p (not DECRQM) not implemented")
            }

        // --- Window Manipulation ---
        case 0x74: // 't' - XTWINOPS (Window manipulation)
            handleWindowManipulation(params)

        default:
            let finalChar = String(Unicode.Scalar(final))
            let intermediates = params.intermediatesDescription
            let paramsDesc = params.paramsDescription
            onUnhandledSequence?(
                "CSI \(intermediates)\(paramsDesc)\(finalChar) not implemented"
            )
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
            savedModes = nil
            currentHyperlinkId = 0
            hyperlinkRegistry.clear()

        case 0x5C: // '\' - ST (String Terminator, 7-bit form ESC \)
            // Parser dispatches ESC \ as a normal ESC sequence after exiting
            // string state; we silently ignore it here because the string
            // content has already been handled.
            break

        case 0x3D: // '=' - DECKPAM (Keypad Application Mode)
            modes.set(.keypadApplication, true)

        case 0x3E: // '>' - DECKPNM (Keypad Numeric Mode)
            modes.set(.keypadApplication, false)

        default:
            let finalChar = String(Unicode.Scalar(final))
            onUnhandledSequence?("ESC \(finalChar) not implemented")
        }
    }

    private func handleESCCharset(final: UInt8, intermediate: UInt8) {
        let slot: ACSCharsetMapper.Slot
        switch intermediate {
        case 0x28: slot = .g0 // '('
        case 0x29: slot = .g1 // ')'
        default:
            onUnhandledSequence?("ESC \(String(Unicode.Scalar(intermediate)))\(String(Unicode.Scalar(final))) (charset select) not implemented")
            return
        }

        let set: ACSCharsetMapper.Set
        switch final {
        case 0x30: set = .decSpecial // '0'
        case 0x42: set = .ascii      // 'B'
        default:
            onUnhandledSequence?("ESC \(String(Unicode.Scalar(intermediate)))\(String(Unicode.Scalar(final))) (charset set) not implemented")
            return
        }

        screen.charsetState.configure(slot: slot, set: set)
    }

    private func handleESCCharsetSelect(final: UInt8) {
        // ESC %@ — Select default character set (ISO 2022 / Latin-1)
        // ESC %G — Select UTF-8 character set
        // The terminal is always UTF-8; these sequences are accepted
        // silently so vttest encoding-switch tests pass.
        switch final {
        case 0x40: // '@'
            break // default charset — no-op, we stay in UTF-8
        case 0x47: // 'G'
            break // UTF-8 — already the default
        default:
            onUnhandledSequence?("ESC %\(String(Unicode.Scalar(final))) (charset select) not implemented")
        }
    }

    private func handleESCLineSize(final: UInt8) {
        // ESC # 3 — DECDHL top half
        // ESC # 4 — DECDHL bottom half
        // ESC # 5 — DECSWL (single-width single-height)
        // ESC # 6 — DECDWL (double-width single-height)
        switch final {
        case 0x33: // '3' — DECDHL top half
            screen.setLineSize(height: .doubleTop, width: .double)
        case 0x34: // '4' — DECDHL bottom half
            screen.setLineSize(height: .doubleBottom, width: .double)
        case 0x35: // '5' — DECSWL (normal)
            screen.setLineSize(height: .normal, width: .normal)
        case 0x36: // '6' — DECDWL (double-width)
            screen.setLineSize(height: .normal, width: .double)
        case 0x38: // '8' — DECALN (Screen Alignment Pattern)
            screen.fillWithE()
        default:
            onUnhandledSequence?("ESC # \(String(Unicode.Scalar(final))) (line size) not implemented")
        }
    }

    // MARK: - OSC Dispatch

    private mutating func handleOSC(_ data: [UInt8]) {
        // Parse "number;string" format (semicolon is optional for reset sequences like OSC 117)
        let numBytes: ArraySlice<UInt8>
        let stringData: ArraySlice<UInt8>
        if let separatorIdx = data.firstIndex(of: 0x3B) {
            numBytes = data[0..<separatorIdx]
            stringData = data[(separatorIdx + 1)...]
        } else {
            numBytes = data[0...]
            stringData = []
        }
        guard let numStr = String(bytes: numBytes, encoding: .utf8),
              let oscNum = Int(numStr) else { return }

        switch oscNum {
        case 0, 1, 2: // Set window title (0=both, 1=icon, 2=window)
            if !stringData.isEmpty, let raw = String(bytes: stringData, encoding: .utf8) {
                let title = Self.sanitizeTitle(raw)
                currentTitle = title
                onTitleChanged?(title)
            }
        case 7:
            handleOSC7(stringData)
        case 4:
            handleOSC4(stringData)
        case 8:
            handleOSC8(stringData)
        case 52:
            handleOSC52(stringData)
        case 7727:
            handleOSC7727(stringData)
        case 9:
            handleOSC9(stringData)
        case 777:
            handleOSC777(stringData)
        case 10:
            handleOSC10(stringData)
        case 11:
            handleOSC11(stringData)
        case 12:
            handleOSC12(stringData)
        case 13:
            handleOSC13(stringData)
        case 14:
            handleOSC14(stringData)
        case 17:
            handleOSC17(stringData)
        case 19:
            handleOSC19(stringData)
        case 22:
            handleOSC22(stringData)
        case 110:
            onDynamicColorReset?(10)
        case 111:
            onDynamicColorReset?(11)
        case 112:
            onDynamicColorReset?(12)
        case 117:
            onDynamicColorReset?(17)
        case 119:
            onDynamicColorReset?(19)
        case 15, 16:
            // OSC 15/16 (Tektronix foreground/background color) — intentionally ignored.
            break
        case 66:
            // OSC 66 (Kitty text sizing protocol) — intentionally ignored for now.
            break
        case 1337:
            handleOSC1337(stringData)
        default:
            onUnhandledSequence?("OSC \(oscNum) not implemented")
        }
    }

    /// Strip C0/C1 control characters and truncate to maxTitleLength in a single pass.
    public static func sanitizeTitle(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F || (v >= 0x80 && v <= 0x9F) { continue }
            scalars.append(scalar)
            if scalars.count >= maxTitleLength { break }
        }
        return String(scalars)
    }

    // MARK: - OSC 7 (Current Working Directory)

    /// Handle OSC 7 `file://hostname/path` sequences.
    private func handleOSC7(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }
        // Parse file://hostname/path — strip the scheme and hostname
        guard str.hasPrefix("file://") else { return }
        let afterScheme = str.dropFirst("file://".count)
        // Skip hostname (up to next '/')
        guard let pathStart = afterScheme.firstIndex(of: "/") else { return }
        let path = String(afterScheme[pathStart...])
        guard !path.isEmpty else { return }
        onWorkingDirectoryChanged?(path)
    }

    // MARK: - OSC 52 (Clipboard)

    /// Handle OSC 52 clipboard operations.
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

    // MARK: - OSC 7727 (Shell Integration)

    private func handleOSC7727(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8) else { return }
        if str.hasPrefix("running-command=") {
            let cmd = String(str.dropFirst("running-command=".count))
            if !cmd.isEmpty {
                onRunningCommandChanged?(cmd)
            }
        } else if str == "shell-prompt" {
            onRunningCommandChanged?(nil)
        }
    }

    // MARK: - OSC 9 (Notification)

    private func handleOSC9(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }
        let (title, body) = splitNotification(str)
        onPaneNotification?(title, body)
    }

    // MARK: - OSC 777 (Notification)

    private func handleOSC777(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }
        let parts = str.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "notify" else { return }
        let title = String(parts[1])
        let body = parts.count >= 3 ? String(parts[2]) : title
        onPaneNotification?(title, body)
    }

    // MARK: - OSC 8 (Hyperlinks)

    /// Handle OSC 8 hyperlink sequences.
    /// Format: `\033]8;params;URL\033\\`
    /// - `params`: semicolon-separated key=value pairs, e.g. `id=abc`
    /// - `URL`: the hyperlink target (empty string means close hyperlink)
    private mutating func handleOSC8(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8) else { return }

        // Split "params;url" at the first semicolon
        let parts = str.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }

        let params = String(parts[0])
        let url = String(parts[1])

        if url.isEmpty {
            // Close hyperlink
            currentHyperlinkId = 0
        } else {
            // Parse optional id=... parameter
            var explicitId: String?
            for param in params.split(separator: ":", omittingEmptySubsequences: false) {
                let trimmed = param.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("id=") {
                    explicitId = String(trimmed.dropFirst(3))
                    break
                }
            }
            currentHyperlinkId = hyperlinkRegistry.register(url: url, explicitId: explicitId)
        }

        // Update current attributes with the hyperlink ID
        currentAttributes.hyperlinkId = currentHyperlinkId
    }

    // MARK: - OSC 10 (Foreground Color)

    private func handleOSC10(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 10, data: data)
    }

    // MARK: - OSC 11 (Background Color)

    private func handleOSC11(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 11, data: data)
    }

    // MARK: - OSC 12 (Cursor Color)

    private func handleOSC12(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 12, data: data)
    }

    // MARK: - OSC 13 (Pointer Foreground Color)

    private func handleOSC13(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 13, data: data)
    }

    // MARK: - OSC 14 (Pointer Background Color)

    private func handleOSC14(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 14, data: data)
    }

    // MARK: - OSC 4 (Set/Query Palette Color)

    /// Handle OSC 4 palette color sequences.
    /// Format: OSC 4 ; idx1 ; color1 ; idx2 ; color2 ; ... ST
    /// Each idx is a palette index (0-255), color is a color spec or "?" for query.
    private func handleOSC4(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }

        // Split by semicolons into pairs of (index, color)
        let parts = str.split(separator: ";", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return }

        var i = 0
        while i < parts.count {
            guard let index = Int(parts[i]), (0...255).contains(index) else {
                i += 1
                continue
            }
            i += 1
            guard i < parts.count else { break }
            let colorSpec = String(parts[i])
            i += 1

            if colorSpec == "?" {
                guard let color = onPaletteColorQuery?(index) else { continue }
                let response = "\u{1B}]4;\(index);\(color.xtermRGBString)\u{07}"
                onWriteBack?(Data(response.utf8))
            } else if let color = parseXtermColor(colorSpec) {
                onPaletteColorSet?(index, color)
            }
        }
    }

    // MARK: - OSC 17 (Selection Background Color)

    private func handleOSC17(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 17, data: data)
    }

    // MARK: - OSC 19 (Selection Foreground Color)

    private func handleOSC19(_ data: ArraySlice<UInt8>) {
        handleOSCDynamicColor(oscNumber: 19, data: data)
    }

    // MARK: - OSC 22 (Pointer Shape)

    /// Handle OSC 22 pointer shape sequences.
    /// Format: OSC 22 ; shape ST/BEL
    /// Shape names follow X11 / CSS cursor names.
    private func handleOSC22(_ data: ArraySlice<UInt8>) {
        guard let shape = String(bytes: data, encoding: .utf8), !shape.isEmpty else { return }
        onPointerShapeChanged?(shape)
    }

    /// Shared handler for OSC 10/11/12/13/14/17/19 dynamic colors.
    /// - Parameter oscNumber: The OSC number (10=foreground, 11=background, 12=cursor, 13=pointer fg, 14=pointer bg, 17=selection bg, 19=selection fg)
    /// - Parameter data: The payload after the semicolon.
    private func handleOSCDynamicColor(oscNumber: Int, data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }

        // Query: "?"
        if str == "?" {
            guard let color = onDynamicColorQuery?(oscNumber) else { return }
            let response = "\u{1B}]\(oscNumber);\(color.xtermRGBString)\u{07}"
            onWriteBack?(Data(response.utf8))
            return
        }

        // Set: try to parse the color spec.
        if let color = parseXtermColor(str) {
            onDynamicColorSet?(oscNumber, color)
        }
    }

    /// Parse an xterm color specification into RGBColor.
    /// Supports:
    /// - `rgb:RRRR/GGGG/BBBB` (X11 format, 1-4 hex digits per component)
    /// - `#RRGGBB` or `#RGB` (hex)
    private func parseXtermColor(_ spec: String) -> RGBColor? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)

        // X11 rgb:RRRR/GGGG/BBBB format
        if trimmed.hasPrefix("rgb:") {
            let rest = trimmed.dropFirst("rgb:".count)
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            guard let r = parseHexComponent(String(parts[0])),
                  let g = parseHexComponent(String(parts[1])),
                  let b = parseHexComponent(String(parts[2]))
            else { return nil }
            return RGBColor(r: r, g: g, b: b)
        }

        // #RRGGBB or #RGB format
        if trimmed.hasPrefix("#") {
            let hex = trimmed.dropFirst()
            if hex.count == 6 {
                guard let r = UInt8(hex.prefix(2), radix: 16),
                      let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                      let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
                else { return nil }
                return RGBColor(r: r, g: g, b: b)
            } else if hex.count == 3 {
                guard let r4 = UInt8(hex.prefix(1), radix: 16),
                      let g4 = UInt8(hex.dropFirst(1).prefix(1), radix: 16),
                      let b4 = UInt8(hex.dropFirst(2).prefix(1), radix: 16)
                else { return nil }
                let r = (r4 << 4) | r4
                let g = (g4 << 4) | g4
                let b = (b4 << 4) | b4
                return RGBColor(r: r, g: g, b: b)
            }
        }

        return nil
    }

    /// Parse a hex component string of 1-4 digits, scaling to 8-bit.
    private func parseHexComponent(_ s: String) -> UInt8? {
        guard let value = UInt16(s, radix: 16) else { return nil }
        let digitCount = s.count
        switch digitCount {
        case 1:
            // 4-bit -> 8-bit: replicate
            let v = UInt8(value)
            return (v << 4) | v
        case 2:
            return UInt8(value)
        case 3:
            // 12-bit -> 8-bit: shift right 4
            return UInt8(value >> 4)
        case 4:
            // 16-bit -> 8-bit: shift right 8
            return UInt8(value >> 8)
        default:
            return nil
        }
    }

    // MARK: - OSC 1337 (iTerm2 Notification)

    private func handleOSC1337(_ data: ArraySlice<UInt8>) {
        guard let str = String(bytes: data, encoding: .utf8), !str.isEmpty else { return }
        let prefix = "Notify="
        guard str.hasPrefix(prefix) else { return }
        let remainder = String(str.dropFirst(prefix.count))
        let (title, body) = splitNotification(remainder)
        onPaneNotification?(title, body)
    }

    // MARK: - Notification Helpers

    /// Split "title;body" into (title, body). If no separator, body = title.
    private func splitNotification(_ str: String) -> (String, String) {
        if let idx = str.firstIndex(of: ";") {
            let title = String(str[..<idx])
            let body = String(str[str.index(after: idx)...])
            return (title, body)
        }
        return (str, str)
    }

    // MARK: - Window Manipulation (CSI t)

    private mutating func handleWindowManipulation(_ params: CSIParams) {
        guard params.count >= 1 else { return }
        switch params[0] {
        case 14: // Report text area size in pixels
            let size = onWindowPixelSizeRequest?() ?? (width: 0, height: 0)
            let response = "\u{1B}[4;\(size.height);\(size.width)t"
            onWriteBack?(Data(response.utf8))

        case 21: // Report window title: respond with OSC l <title> ST
            let response = "\u{1B}]l\(currentTitle)\u{1B}\\"
            onWriteBack?(Data(response.utf8))

        case 22: // Push title onto stack
            let kind = params.count >= 2 ? params[1] : 0
            // kind 0 = both icon and window title, 2 = window title only
            if kind == 0 || kind == 2 {
                if titleStack.count >= Self.maxTitleStackDepth {
                    titleStack.removeFirst()
                }
                titleStack.append(currentTitle)
            }

        case 23: // Pop title from stack
            let kind = params.count >= 2 ? params[1] : 0
            if kind == 0 || kind == 2 {
                if let restored = titleStack.popLast() {
                    currentTitle = restored
                    onTitleChanged?(restored)
                }
            }

        default:
            onUnhandledSequence?("CSI t \(params[0]) (window manipulation) not implemented")
        }
    }

    // MARK: - XTMODKEYS

    /// Handle `CSI > Pp ; Pv m` (xterm key modifier options).
    /// Only `Pp = 4` (modifyOtherKeys) is currently supported.
    private mutating func handleXTMODKEYS(_ params: CSIParams) {
        if params.count == 0 {
            // No parameters: reset all XTMODKEYS resources.
            modes.modifyOtherKeys = 0
            return
        }

        let resource = params[0]
        let value = params.count >= 2 ? params[1] : 0

        switch resource {
        case 4:
            modes.modifyOtherKeys = UInt8(clamping: value)
        default:
            onUnhandledSequence?("XTMODKEYS resource \(resource) not implemented")
        }
    }

    // MARK: - ANSI Mode Set/Reset

    private mutating func setANSIMode(_ rawParam: UInt16, value: Bool) {
        guard let mode = TerminalModes.ansiFrom(rawValue: rawParam) else {
            onUnhandledSequence?("ANSI SM/RM mode \(rawParam) not implemented")
            return
        }
        modes.set(mode, value)

        // Side effects
        switch mode {
        case .insert:
            screen.setInsertMode(value)
        case .newline:
            // LNM is read directly in handleExecute; no side effect needed here.
            break
        }
    }

    // MARK: - DEC Mode Set/Reset

    private mutating func setDECMode(_ rawParam: UInt16, value: Bool) {
        // Try mouse tracking modes first (9, 1000, 1002, 1003)
        if modes.setMouseTracking(rawParam: rawParam, enabled: value) { return }
        // Try mouse format modes (1006)
        if modes.setMouseFormat(rawParam: rawParam, enabled: value) { return }

        guard let mode = TerminalModes.from(rawValue: rawParam) else {
            onUnhandledSequence?("DECSET/DECRST mode \(rawParam) not implemented")
            return
        }

        modes.set(mode, value)

        // Side effects
        switch mode {
        case .cursorKeys, .bracketedPaste, .columnMode, .smoothScroll, .graphemeClustering:
            // Passive modes: recognized and stored, but either have no side
            // effects in this method (consumers read the bitfield directly)
            // or their full implementation is deferred.
            break
        case .reverseVideo:
            screen.setReverseVideo(value)
        case .originMode:
            screen.setOriginMode(value)
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
        case .focusEvents:
            onFocusReportingChanged?(value)
        case .colorSchemeReporting:
            onColorSchemeReportingChanged?(value)
        case .syncedUpdate:
            if value {
                screen.beginSyncedUpdate()
            } else {
                screen.endSyncedUpdate()
            }
        default:
            onUnhandledSequence?("DEC mode \(mode) side effects not implemented")
        }
    }

    // MARK: - DECRQM (Request Mode)

    /// Respond to a DECRQM query. Supports modes 1004 (focus events),
    /// 2026 (synchronized output), and 2027 (grapheme clustering).
    /// Response format:
    /// `CSI ? <mode> ; <state> $ y` where state is 1 (set) or 2 (reset).
    private mutating func handleDECRQM(_ params: CSIParams) {
        guard params.count >= 1 else { return }
        let mode = params[0]
        let state: Int?
        switch mode {
        case 1004:
            state = modes.isSet(.focusEvents) ? 1 : 2
        case 1016:
            state = modes.mouseFormat == .sgrPixels ? 1 : 2
        case 2004:
            state = modes.isSet(.bracketedPaste) ? 1 : 2
        case 2026:
            state = screen.syncedUpdateActive ? 1 : 2
        case 2027:
            state = modes.isSet(.graphemeClustering) ? 1 : 2
        case 2031:
            state = modes.isSet(.colorSchemeReporting) ? 1 : 2
        default:
            onUnhandledSequence?("DECRQM query for mode \(mode) not implemented")
            return
        }
        let response = "\u{1B}[?\(mode);\(state!)$y"
        onWriteBack?(Data(response.utf8))
    }

    // MARK: - DSR (Device Status Report)

    private func handleDSR(_ params: CSIParams) {
        guard params.count >= 1 else { return }
        switch params[0] {
        case 6: // Report cursor position
            let row: Int
            if modes.isSet(.originMode) {
                row = screen.cursorRow - screen.scrollTop + 1
            } else {
                row = screen.cursorRow + 1
            }
            let col = screen.cursorCol + 1
            let response = "\u{1B}[\(row);\(col)R"
            onWriteBack?(Data(response.utf8))
        case 5: // Status report — report OK
            onWriteBack?(Data("\u{1B}[0n".utf8))
        case 996, 997: // Color scheme query (DECDSR 996/997)
            let isDark = onColorSchemeQuery?() ?? false
            let ps = isDark ? 1 : 2
            onWriteBack?(Data("\u{1B}[?997;\(ps)n".utf8))
        default:
            onUnhandledSequence?("DSR \(params[0]) not implemented")
        }
    }

    // MARK: - Cursor Save / Restore

    private mutating func saveCursor() {
        savedCursor = SavedCursorState(
            col: screen.cursorCol,
            row: screen.cursorRow,
            attributes: currentAttributes,
            charsetState: screen.charsetState,
            originMode: screen.originMode,
            pendingWrap: screen.pendingWrap
        )
    }

    private mutating func restoreCursor() {
        guard let saved = savedCursor else { return }
        screen.setCursorPos(row: saved.row, col: saved.col)
        currentAttributes = saved.attributes
        screen.charsetState = saved.charsetState
        screen.setOriginMode(saved.originMode)
        screen.setPendingWrap(saved.pendingWrap)
    }

    // MARK: - Mode Save / Restore

    private mutating func saveModes() {
        savedModes = modes
    }

    private mutating func restoreModes() {
        guard let saved = savedModes else { return }
        let current = modes

        // DEC modes — only trigger side effects for changed modes
        let decModes: [TerminalModes.Mode] = [
            .cursorKeys, .columnMode, .smoothScroll, .reverseVideo,
            .originMode, .autowrap, .cursorVisible, .focusEvents,
            .altScreen, .bracketedPaste, .syncedUpdate, .graphemeClustering,
            .colorSchemeReporting, .keypadApplication
        ]
        for mode in decModes {
            let savedValue = saved.isSet(mode)
            if savedValue != current.isSet(mode) {
                setDECMode(mode.rawValue, value: savedValue)
            }
        }

        // ANSI modes
        let ansiModes: [TerminalModes.ANSIMode] = [.insert, .newline]
        for mode in ansiModes {
            let savedValue = saved.isSet(mode)
            if savedValue != current.isSet(mode) {
                setANSIMode(mode.rawValue, value: savedValue)
            }
        }

        // Mouse tracking and format have no side effects; copy directly
        modes.mouseTracking = saved.mouseTracking
        modes.mouseFormat = saved.mouseFormat
    }

    // MARK: - Private

    /// Attributes used for erase operations (keeps current bg color, clears everything else).
    private var eraseAttributes: CellAttributes {
        var attrs = CellAttributes.default
        attrs.bgColor = currentAttributes.bgColor
        return attrs
    }
}
