/// Streaming UTF-8 decoder that correctly handles multi-byte sequences split across chunks.
public struct UTF8Decoder: Sendable {

    private var pending: [UInt8] = []
    private var expectedLength: Int = 0

    public init() {}

    /// Feed raw bytes and emit decoded Unicode scalars via the callback.
    /// Incomplete sequences at the end of a chunk are buffered for the next call.
    public mutating func decode(_ bytes: UnsafeBufferPointer<UInt8>, emit: (Unicode.Scalar) -> Void) {
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]

            if pending.isEmpty {
                // Start of a new sequence
                let len = Self.sequenceLength(byte)
                if len == 0 {
                    // Invalid leading byte
                    emit(Self.replacement)
                    i += 1
                    continue
                }
                if len == 1 {
                    // ASCII fast path
                    emit(Unicode.Scalar(byte))
                    i += 1
                    continue
                }
                // Multi-byte sequence
                expectedLength = len
                pending.append(byte)
                i += 1
            } else {
                // Continuation byte expected
                if Self.isContinuation(byte) {
                    pending.append(byte)
                    i += 1
                    if pending.count == expectedLength {
                        // Complete sequence — decode it
                        if let scalar = Self.decodeSequence(pending) {
                            emit(scalar)
                        } else {
                            emit(Self.replacement)
                        }
                        pending.removeAll(keepingCapacity: true)
                        expectedLength = 0
                    }
                } else {
                    // Invalid continuation — emit replacement for the pending bytes and retry this byte
                    emit(Self.replacement)
                    pending.removeAll(keepingCapacity: true)
                    expectedLength = 0
                    // Do not advance i — re-process this byte as a new sequence start
                }
            }
        }
    }

    /// Feed a single byte and emit a decoded scalar via the callback.
    public mutating func decode(_ byte: UInt8, emit: (Unicode.Scalar) -> Void) {
        withUnsafePointer(to: byte) { ptr in
            decode(UnsafeBufferPointer(start: ptr, count: 1), emit: emit)
        }
    }

    /// Reset internal state, discarding any buffered bytes.
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        expectedLength = 0
    }

    // MARK: - Private

    private static let replacement = Unicode.Scalar(0xFFFD)!

    /// Determine the expected byte length from the leading byte.
    /// Returns 0 for invalid leading bytes.
    private static func sequenceLength(_ byte: UInt8) -> Int {
        if byte & 0x80 == 0x00 { return 1 }       // 0xxxxxxx
        if byte & 0xE0 == 0xC0 { return 2 }       // 110xxxxx
        if byte & 0xF0 == 0xE0 { return 3 }       // 1110xxxx
        if byte & 0xF8 == 0xF0 { return 4 }       // 11110xxx
        return 0                                    // continuation or invalid
    }

    /// Check if a byte is a UTF-8 continuation byte (10xxxxxx).
    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    /// Decode a complete UTF-8 byte sequence into a Unicode scalar.
    private static func decodeSequence(_ bytes: [UInt8]) -> Unicode.Scalar? {
        let value: UInt32
        switch bytes.count {
        case 2:
            value = (UInt32(bytes[0] & 0x1F) << 6)
                  | UInt32(bytes[1] & 0x3F)
            // Reject overlong encoding
            guard value >= 0x80 else { return nil }
        case 3:
            value = (UInt32(bytes[0] & 0x0F) << 12)
                  | (UInt32(bytes[1] & 0x3F) << 6)
                  | UInt32(bytes[2] & 0x3F)
            // Reject overlong and surrogates
            guard value >= 0x800, !(0xD800...0xDFFF).contains(value) else { return nil }
        case 4:
            value = (UInt32(bytes[0] & 0x07) << 18)
                  | (UInt32(bytes[1] & 0x3F) << 12)
                  | (UInt32(bytes[2] & 0x3F) << 6)
                  | UInt32(bytes[3] & 0x3F)
            // Reject overlong and out-of-range
            guard value >= 0x10000, value <= 0x10FFFF else { return nil }
        default:
            return nil
        }
        return Unicode.Scalar(value)
    }
}
