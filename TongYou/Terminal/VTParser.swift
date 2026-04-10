/// VT-series parser for escape and control sequences.
///
/// Implements the state machine described on vt100.net:
/// https://vt100.net/emu/dec_ansi_parser
///
/// Reference: Ghostty `src/terminal/Parser.zig` and `src/terminal/parse_table.zig`.
struct VTParser {

    // MARK: - State

    private var state: VTState = .ground
    private var params = CSIParams()
    private var paramAcc: UInt16 = 0
    private var paramAccIdx: UInt8 = 0
    private var oscData: [UInt8] = []
    private var utf8Decoder = UTF8Decoder()
    /// Remaining continuation bytes for an in-progress UTF-8 multi-byte sequence.
    private var utf8Remaining: UInt8 = 0

    private var printBuffer = PrintBatchBuffer()
    private var printBufferCount: Int = 0

    // MARK: - Public API

    /// Feed a buffer of raw bytes and emit actions via the callback.
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, emit: (VTAction) -> Void) {
        var i = 0
        let count = bytes.count
        while i < count {
            if state == .ground && utf8Remaining == 0 {
                let c = bytes[i]
                if c >= 0x20 && c < 0x7F {
                    i = collectPrintableASCII(bytes, from: i, emit: emit)
                    continue
                }
                // CSI fast path: ESC [ in ground state
                if c == 0x1B && i + 2 < count && bytes[i + 1] == 0x5B {
                    let advanced = tryCSIFastPath(bytes, from: i, emit: emit)
                    if advanced > 0 {
                        i = advanced
                        continue
                    }
                }
            }
            // Flush pending print buffer before falling into the state machine
            if printBufferCount > 0 {
                flushPrintBuffer(emit: emit)
            }
            process(bytes[i], emit: emit)
            i += 1
        }
        flushPrintBuffer(emit: emit)
    }

    // MARK: - Print Buffer

    /// Avoids per-byte state machine transitions for the common case of plain ASCII text.
    /// Scans ahead and bulk-copies into the print buffer. Returns index past last consumed byte.
    private mutating func collectPrintableASCII(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, emit: (VTAction) -> Void
    ) -> Int {
        var i = start
        let count = bytes.count
        while i < count {
            // Scan ahead to find the end of the printable ASCII run
            var runEnd = i
            let spaceLeft = PrintBatchBuffer.capacity - printBufferCount
            let scanLimit = min(i + spaceLeft, count)
            while runEnd < scanLimit {
                let c = bytes[runEnd]
                guard c >= 0x20 && c < 0x7F else { break }
                runEnd += 1
            }
            let runLen = runEnd - i
            if runLen == 0 { break }

            printBuffer.copyFrom(bytes, srcOffset: i, count: runLen, at: printBufferCount)
            printBufferCount += runLen
            i = runEnd

            if printBufferCount == PrintBatchBuffer.capacity {
                flushPrintBuffer(emit: emit)
            }
        }
        return i
    }

    private mutating func flushPrintBuffer(emit: (VTAction) -> Void) {
        guard printBufferCount > 0 else { return }
        if printBufferCount == 1 {
            emit(.print(Unicode.Scalar(printBuffer[0])))
        } else {
            emit(.printBatch(count: printBufferCount, buffer: printBuffer))
        }
        printBufferCount = 0
    }

    // MARK: - CSI Fast Path

    /// Try to fast-parse a simple CSI sequence (SGR/CUP/EL/HVP) starting at ESC.
    /// Returns index past last consumed byte on success, or 0 to fall back to state machine.
    /// Bails on intermediates, colons, or incomplete sequences — zero-cost fallback.
    private mutating func tryCSIFastPath(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, emit: (VTAction) -> Void
    ) -> Int {
        flushPrintBuffer(emit: emit)

        let count = bytes.count
        var i = start + 2  // skip ESC [
        var fastParams = CSIParams()
        var acc: UInt16 = 0
        var accIdx: UInt8 = 0

        while i < count {
            let c = bytes[i]
            switch c {
            case 0x30...0x39: // digit
                guard Self.accumulateDigit(c, acc: &acc, accIdx: &accIdx) else { return 0 }

            case 0x3B: // ';' separator
                guard fastParams.count < CSIParams.maxParams else { return 0 }
                fastParams.finalizeParam(acc)
                acc = 0
                accIdx = 0

            case 0x6D, 0x48, 0x4B, 0x66: // 'm' (SGR), 'H' (CUP), 'K' (EL), 'f' (HVP)
                guard fastParams.count < CSIParams.maxParams else { return 0 }
                if accIdx > 0 {
                    fastParams.finalizeParam(acc)
                }
                fastParams.finalByte = c
                emit(.csiDispatch(fastParams))
                return i + 1

            default:
                return 0
            }
            i += 1
        }
        return 0
    }

    // MARK: - Shared Helpers

    /// Accumulate a decimal digit with overflow checking. Returns false on overflow.
    @inline(__always)
    private static func accumulateDigit(_ c: UInt8, acc: inout UInt16, accIdx: inout UInt8) -> Bool {
        let (newAcc, ov1) = acc.multipliedReportingOverflow(by: 10)
        guard !ov1 else { return false }
        let (newAcc2, ov2) = newAcc.addingReportingOverflow(UInt16(c &- 0x30))
        guard !ov2 else { return false }
        acc = newAcc2
        let (newIdx, ov3) = accIdx.addingReportingOverflow(1)
        guard !ov3 else { return false }
        accIdx = newIdx
        return true
    }

    // MARK: - Core Processing

    private mutating func process(_ c: UInt8, emit: (VTAction) -> Void) {
        // Ground state UTF-8 multi-byte handling:
        // When we're collecting continuation bytes for a multi-byte sequence,
        // consume them directly (the table maps 0x80-0x9F to C1 execute,
        // which would break UTF-8 sequences). This mirrors how Ghostty's
        // stream.zig handles UTF-8 at the stream level before the parser.
        if state == .ground && utf8Remaining > 0 {
            utf8Remaining -= 1
            if let action = processUTF8Byte(c) {
                emit(action)
            }
            return
        }

        // For UTF-8 leading bytes in ground state (0xC0-0xFF),
        // start a multi-byte sequence instead of using the table.
        if state == .ground && c >= 0xC0 {
            let expected: UInt8
            if c & 0xE0 == 0xC0 { expected = 1 }      // 2-byte: 110xxxxx
            else if c & 0xF0 == 0xE0 { expected = 2 }  // 3-byte: 1110xxxx
            else if c & 0xF8 == 0xF0 { expected = 3 }  // 4-byte: 11110xxx
            else { expected = 0 }                        // invalid leading byte

            if expected > 0 {
                utf8Remaining = expected
                _ = processUTF8Byte(c)
                return
            }
        }

        let entry = Self.table[Int(c) &* VTState.count + Int(state.rawValue)]
        let nextState = entry.state
        let action = entry.action

        // Three-phase action execution: exit → transition → entry
        // (matching Ghostty's Parser.next() structure)

        // Phase 1: Exit action from current state (only when state changes)
        if state != nextState {
            switch state {
            case .oscString:
                emit(.oscDispatch(oscData))
                oscData.removeAll(keepingCapacity: true)
            case .dcsPassthrough:
                emit(.dcsUnhook)
            case .sosPmApcString:
                emit(.apcEnd)
            default:
                break
            }
        }

        // Phase 2: Transition action
        if let vtAction = doAction(action, c) {
            emit(vtAction)
        }

        // Phase 3: Entry action to new state (only when state changes)
        if state != nextState {
            switch nextState {
            case .escape, .dcsEntry, .csiEntry:
                clear()
            case .oscString:
                oscData.removeAll(keepingCapacity: true)
            case .dcsPassthrough:
                finalizeDCSHook(c, emit: emit)
            case .sosPmApcString:
                emit(.apcStart)
            default:
                break
            }
        }

        state = nextState
    }

    // MARK: - Action Execution

    private mutating func doAction(_ action: TransitionAction, _ c: UInt8) -> VTAction? {
        switch action {
        case .none, .ignore:
            return nil

        case .print:
            if c < 0x80 {
                return .print(Unicode.Scalar(c))
            }
            return processUTF8Byte(c)

        case .execute:
            return .execute(c)

        case .collect:
            params.addIntermediate(c)
            return nil

        case .param:
            if c == 0x3B { // ';' semicolon separator
                if params.count < CSIParams.maxParams {
                    params.finalizeParam(paramAcc)
                }
                paramAcc = 0
                paramAccIdx = 0
                return nil
            }
            if c == 0x3A { // ':' colon separator
                if params.count < CSIParams.maxParams {
                    params.finalizeParam(paramAcc)
                    params.markColon()
                }
                paramAcc = 0
                paramAccIdx = 0
                return nil
            }
            // Digit 0-9
            if !Self.accumulateDigit(c, acc: &paramAcc, accIdx: &paramAccIdx) {
                return nil
            }
            return nil

        case .csiDispatch:
            guard params.count < CSIParams.maxParams else { return nil }
            if paramAccIdx > 0 {
                params.finalizeParam(paramAcc)
            }
            params.finalByte = c

            // Colon separators are only valid for SGR ('m' command)
            if c != 0x6D /* m */ && params.colonMask != 0 {
                return nil
            }

            return .csiDispatch(params)

        case .escDispatch:
            let im = (
                params.intermediateCount > 0 ? params.intermediate(0) : 0,
                params.intermediateCount > 1 ? params.intermediate(1) : 0,
                params.intermediateCount > 2 ? params.intermediate(2) : 0,
                params.intermediateCount > 3 ? params.intermediate(3) : 0
            )
            return .escDispatch(final: c, intermediateCount: params.intermediateCount, intermediates: im)

        case .oscPut:
            if oscData.count < 4096 {
                oscData.append(c)
            }
            return nil

        case .put:
            return .dcsPut(c)

        case .apcPut:
            return .apcPut(c)
        }
    }

    private mutating func processUTF8Byte(_ c: UInt8) -> VTAction? {
        var result: VTAction?
        utf8Decoder.decode(c) { scalar in
            result = .print(scalar)
        }
        return result
    }

    private mutating func finalizeDCSHook(_ c: UInt8, emit: (VTAction) -> Void) {
        guard params.count < CSIParams.maxParams else { return }
        if paramAccIdx > 0 {
            params.finalizeParam(paramAcc)
        }
        params.finalByte = c
        emit(.dcsHook(params))
    }

    private mutating func clear() {
        params.reset()
        paramAcc = 0
        paramAccIdx = 0
    }
}

// MARK: - VT State

enum VTState: UInt8, CaseIterable {
    case ground = 0
    case escape
    case escapeIntermediate
    case csiEntry
    case csiParam
    case csiIntermediate
    case csiIgnore
    case dcsEntry
    case dcsParam
    case dcsIntermediate
    case dcsPassthrough
    case dcsIgnore
    case oscString
    case sosPmApcString

    static let count = VTState.allCases.count
}

// MARK: - Transition Table

/// Internal transition action for the state machine table.
private enum TransitionAction: UInt8 {
    case none = 0
    case ignore
    case print
    case execute
    case collect
    case param
    case csiDispatch
    case escDispatch
    case oscPut
    case put
    case apcPut
}

/// A single entry in the state transition table.
private struct Transition {
    let state: VTState
    let action: TransitionAction
}

extension VTParser {

    /// Flattened state transition table: `table[byte * VTState.count + state]`.
    /// Generated once at static init time (3584 entries, ~7KB).
    fileprivate static let table: [Transition] = {
        let stateCount = VTState.count
        var t = [Transition](
            repeating: Transition(state: .ground, action: .none),
            count: 256 * stateCount
        )

        func set(_ byte: UInt8, _ from: VTState, _ to: VTState, _ action: TransitionAction) {
            t[Int(byte) * stateCount + Int(from.rawValue)] = Transition(state: to, action: action)
        }

        func setRange(_ from: UInt8, _ to: UInt8, _ source: VTState, _ dest: VTState, _ action: TransitionAction) {
            for byte in from...to {
                set(byte, source, dest, action)
            }
        }

        // --- Anywhere transitions (from every state) ---
        for source in VTState.allCases {
            // anywhere → ground
            set(0x18, source, .ground, .execute)
            set(0x1A, source, .ground, .execute)
            setRange(0x80, 0x8F, source, .ground, .execute)
            setRange(0x91, 0x97, source, .ground, .execute)
            set(0x99, source, .ground, .execute)
            set(0x9A, source, .ground, .execute)
            set(0x9C, source, .ground, .none)  // ST

            // anywhere → escape
            set(0x1B, source, .escape, .none)

            // anywhere → sos_pm_apc_string
            set(0x98, source, .sosPmApcString, .none)
            set(0x9E, source, .sosPmApcString, .none)
            set(0x9F, source, .sosPmApcString, .none)

            // anywhere → csi_entry
            set(0x9B, source, .csiEntry, .none)

            // anywhere → dcs_entry
            set(0x90, source, .dcsEntry, .none)

            // anywhere → osc_string
            set(0x9D, source, .oscString, .none)
        }

        // --- Ground state ---
        do {
            let s = VTState.ground
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            setRange(0x20, 0x7F, s, s, .print)
        }

        // --- Escape state ---
        do {
            let s = VTState.escape
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x30, 0x4F, s, .ground, .escDispatch)
            setRange(0x51, 0x57, s, .ground, .escDispatch)
            setRange(0x60, 0x7E, s, .ground, .escDispatch)
            set(0x59, s, .ground, .escDispatch)
            set(0x5A, s, .ground, .escDispatch)
            set(0x5C, s, .ground, .escDispatch)

            // → escape_intermediate
            setRange(0x20, 0x2F, s, .escapeIntermediate, .collect)

            // → sos_pm_apc_string
            set(0x58, s, .sosPmApcString, .none)
            set(0x5E, s, .sosPmApcString, .none)
            set(0x5F, s, .sosPmApcString, .none)

            // → dcs_entry
            set(0x50, s, .dcsEntry, .none)

            // → csi_entry
            set(0x5B, s, .csiEntry, .none)

            // → osc_string
            set(0x5D, s, .oscString, .none)
        }

        // --- Escape intermediate ---
        do {
            let s = VTState.escapeIntermediate
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            setRange(0x20, 0x2F, s, s, .collect)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x30, 0x7E, s, .ground, .escDispatch)
        }

        // --- CSI entry ---
        do {
            let s = VTState.csiEntry
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x40, 0x7E, s, .ground, .csiDispatch)

            // → csi_ignore
            set(0x3A, s, .csiIgnore, .none)

            // → csi_intermediate
            setRange(0x20, 0x2F, s, .csiIntermediate, .collect)

            // → csi_param
            setRange(0x30, 0x39, s, .csiParam, .param)
            set(0x3B, s, .csiParam, .param)
            setRange(0x3C, 0x3F, s, .csiParam, .collect)
        }

        // --- CSI param ---
        do {
            let s = VTState.csiParam
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            setRange(0x30, 0x39, s, s, .param)
            set(0x3A, s, s, .param)  // colon for SGR sub-params
            set(0x3B, s, s, .param)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x40, 0x7E, s, .ground, .csiDispatch)

            // → csi_ignore
            setRange(0x3C, 0x3F, s, .csiIgnore, .none)

            // → csi_intermediate
            setRange(0x20, 0x2F, s, .csiIntermediate, .collect)
        }

        // --- CSI intermediate ---
        do {
            let s = VTState.csiIntermediate
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            setRange(0x20, 0x2F, s, s, .collect)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x40, 0x7E, s, .ground, .csiDispatch)

            // → csi_ignore
            setRange(0x30, 0x3F, s, .csiIgnore, .none)
        }

        // --- CSI ignore ---
        do {
            let s = VTState.csiIgnore
            set(0x19, s, s, .execute)
            setRange(0x00, 0x17, s, s, .execute)
            setRange(0x1C, 0x1F, s, s, .execute)
            setRange(0x20, 0x3F, s, s, .ignore)
            set(0x7F, s, s, .ignore)

            // → ground
            setRange(0x40, 0x7E, s, .ground, .none)
        }

        // --- DCS entry ---
        do {
            let s = VTState.dcsEntry
            set(0x19, s, s, .ignore)
            setRange(0x00, 0x17, s, s, .ignore)
            setRange(0x1C, 0x1F, s, s, .ignore)
            set(0x7F, s, s, .ignore)

            // → dcs_intermediate
            setRange(0x20, 0x2F, s, .dcsIntermediate, .collect)

            // → dcs_ignore
            set(0x3A, s, .dcsIgnore, .none)

            // → dcs_param
            setRange(0x30, 0x39, s, .dcsParam, .param)
            set(0x3B, s, .dcsParam, .param)
            setRange(0x3C, 0x3F, s, .dcsParam, .collect)

            // → dcs_passthrough
            setRange(0x40, 0x7E, s, .dcsPassthrough, .none)
        }

        // --- DCS param ---
        do {
            let s = VTState.dcsParam
            set(0x19, s, s, .ignore)
            setRange(0x00, 0x17, s, s, .ignore)
            setRange(0x1C, 0x1F, s, s, .ignore)
            setRange(0x30, 0x39, s, s, .param)
            set(0x3B, s, s, .param)
            set(0x7F, s, s, .ignore)

            // → dcs_ignore
            set(0x3A, s, .dcsIgnore, .none)
            setRange(0x3C, 0x3F, s, .dcsIgnore, .none)

            // → dcs_intermediate
            setRange(0x20, 0x2F, s, .dcsIntermediate, .collect)

            // → dcs_passthrough
            setRange(0x40, 0x7E, s, .dcsPassthrough, .none)
        }

        // --- DCS intermediate ---
        do {
            let s = VTState.dcsIntermediate
            set(0x19, s, s, .ignore)
            setRange(0x00, 0x17, s, s, .ignore)
            setRange(0x1C, 0x1F, s, s, .ignore)
            setRange(0x20, 0x2F, s, s, .collect)
            set(0x7F, s, s, .ignore)

            // → dcs_ignore
            setRange(0x30, 0x3F, s, .dcsIgnore, .none)

            // → dcs_passthrough
            setRange(0x40, 0x7E, s, .dcsPassthrough, .none)
        }

        // --- DCS passthrough ---
        do {
            let s = VTState.dcsPassthrough
            set(0x19, s, s, .put)
            setRange(0x00, 0x17, s, s, .put)
            setRange(0x1C, 0x1F, s, s, .put)
            setRange(0x20, 0x7E, s, s, .put)
            set(0x7F, s, s, .ignore)
        }

        // --- DCS ignore ---
        do {
            let s = VTState.dcsIgnore
            set(0x19, s, s, .ignore)
            setRange(0x00, 0x17, s, s, .ignore)
            setRange(0x1C, 0x1F, s, s, .ignore)
        }

        // --- OSC string ---
        do {
            let s = VTState.oscString
            set(0x19, s, s, .ignore)
            setRange(0x00, 0x06, s, s, .ignore)
            setRange(0x08, 0x17, s, s, .ignore)
            setRange(0x1C, 0x1F, s, s, .ignore)
            setRange(0x20, 0xFF, s, s, .oscPut)

            // BEL terminates OSC (XTerm compatibility)
            set(0x07, s, .ground, .none)
        }

        // --- SOS/PM/APC string ---
        do {
            let s = VTState.sosPmApcString
            set(0x19, s, s, .apcPut)
            setRange(0x00, 0x17, s, s, .apcPut)
            setRange(0x1C, 0x1F, s, s, .apcPut)
            setRange(0x20, 0x7F, s, s, .apcPut)
        }

        return t
    }()
}
