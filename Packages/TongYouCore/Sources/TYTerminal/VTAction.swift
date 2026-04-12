/// Parameters accumulated during CSI sequence parsing.
/// Fixed-size storage (no heap allocation). Max 24 params matching Ghostty.
public struct CSIParams: Sendable {
    public static let maxParams = 24
    public static let maxIntermediates = 4

    /// Parameter values. Uninitialized entries beyond `count` are undefined.
    private var storage: (
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
    ) = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)

    /// Number of finalized parameters.
    public private(set) var count: Int = 0

    /// Bitset tracking colon separators. Bit N set means the separator
    /// after param N was ':' (sub-parameter) rather than ';'.
    public private(set) var colonMask: UInt32 = 0

    /// Intermediate bytes (e.g. '?' for DEC private modes).
    private var intermediateStorage: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    public private(set) var intermediateCount: Int = 0

    /// Final byte of the sequence (e.g. 'H' for CUP, 'm' for SGR).
    public var finalByte: UInt8 = 0

    public init() {}

    // MARK: - Parameter Access

    /// Get param at index, returning `defaultValue` if out of range or zero.
    public func param(_ index: Int, default defaultValue: UInt16 = 0) -> UInt16 {
        guard index < count else { return defaultValue }
        let val = self[index]
        return val == 0 ? defaultValue : val
    }

    public subscript(index: Int) -> UInt16 {
        get {
            precondition(index >= 0 && index < Self.maxParams)
            return withUnsafeBytes(of: storage) { buf in
                buf.load(fromByteOffset: index * MemoryLayout<UInt16>.stride, as: UInt16.self)
            }
        }
        set {
            precondition(index >= 0 && index < Self.maxParams)
            withUnsafeMutableBytes(of: &storage) { buf in
                buf.storeBytes(of: newValue, toByteOffset: index * MemoryLayout<UInt16>.stride, as: UInt16.self)
            }
        }
    }

    /// Whether the separator after param at `index` was a colon.
    public func isColon(at index: Int) -> Bool {
        (colonMask >> UInt32(index)) & 1 != 0
    }

    // MARK: - Intermediate Access

    public func intermediate(_ index: Int) -> UInt8 {
        precondition(index >= 0 && index < Self.maxIntermediates)
        return withUnsafeBytes(of: intermediateStorage) { buf in
            buf.load(fromByteOffset: index, as: UInt8.self)
        }
    }

    /// Check if intermediates contain the given byte (e.g. '?' or ' ').
    public func hasIntermediate(_ byte: UInt8) -> Bool {
        for i in 0..<intermediateCount {
            if intermediate(i) == byte { return true }
        }
        return false
    }

    // MARK: - Building (used by VTParser)

    public mutating func addIntermediate(_ byte: UInt8) {
        guard intermediateCount < Self.maxIntermediates else { return }
        withUnsafeMutableBytes(of: &intermediateStorage) { buf in
            buf.storeBytes(of: byte, toByteOffset: intermediateCount, as: UInt8.self)
        }
        intermediateCount += 1
    }

    /// Finalize the current parameter accumulator value and advance to next slot.
    public mutating func finalizeParam(_ value: UInt16) {
        guard count < Self.maxParams else { return }
        self[count] = value
        count += 1
    }

    /// Mark the separator before the current slot as colon.
    public mutating func markColon() {
        guard count > 0 else { return }
        colonMask |= 1 << UInt32(count - 1)
    }

    public mutating func reset() {
        count = 0
        colonMask = 0
        intermediateCount = 0
        finalByte = 0
    }
}

// MARK: - VT Action

/// Actions emitted by the VT parser to be handled by the stream dispatcher.
public enum VTAction: Sendable {
    /// Print a Unicode codepoint to the screen.
    case print(Unicode.Scalar)

    /// Print a batch of ASCII characters to the screen.
    /// The buffer contains raw ASCII bytes (0x20-0x7F) to be written with current attributes.
    case printBatch(count: Int, buffer: PrintBatchBuffer)

    /// Execute a C0 control character (0x00-0x1F).
    case execute(UInt8)

    /// A complete CSI sequence has been parsed.
    case csiDispatch(CSIParams)

    /// An ESC sequence has been dispatched.
    /// `final` is the final byte. Intermediates stored inline (max 4 bytes, no heap allocation).
    case escDispatch(final: UInt8, intermediateCount: Int, intermediates: (UInt8, UInt8, UInt8, UInt8))

    /// An OSC (Operating System Command) string has been received.
    case oscDispatch([UInt8])

    /// DCS hook — beginning of a DCS sequence.
    case dcsHook(CSIParams)
    /// DCS put — data byte within a DCS sequence.
    case dcsPut(UInt8)
    /// DCS unhook — end of a DCS sequence.
    case dcsUnhook

    /// APC start.
    case apcStart
    /// APC data byte.
    case apcPut(UInt8)
    /// APC end.
    case apcEnd
}

// MARK: - Print Batch Buffer

/// Fixed-size inline buffer for batched ASCII print data.
/// 128 bytes keeps the VTAction enum small while covering typical terminal line widths.
public struct PrintBatchBuffer: Sendable {
    public static let capacity = 128

    // 128 bytes stored as 16 × UInt64 (inline, no heap)
    private var s: (
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
    ) = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)

    public init() {}

    public subscript(index: Int) -> UInt8 {
        get {
            precondition(index >= 0 && index < Self.capacity)
            return withUnsafeBytes(of: s) { $0[index] }
        }
        set {
            precondition(index >= 0 && index < Self.capacity)
            withUnsafeMutableBytes(of: &s) { $0[index] = newValue }
        }
    }

    /// Bulk-copy bytes from source buffer into this buffer at the given offset.
    /// Single withUnsafeMutableBytes call avoids per-byte overhead.
    public mutating func copyFrom(_ src: UnsafeBufferPointer<UInt8>, srcOffset: Int, count: Int, at destOffset: Int) {
        precondition(destOffset + count <= Self.capacity)
        withUnsafeMutableBytes(of: &s) { buf in
            buf.baseAddress!.advanced(by: destOffset)
                .copyMemory(from: src.baseAddress!.advanced(by: srcOffset), byteCount: count)
        }
    }
}
