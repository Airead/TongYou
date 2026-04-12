import Foundation

/// Wire protocol frame format:
/// ```
/// ┌──────────────┬──────────────┬──────────────┬────────────────────┐
/// │ Magic (2B)   │ Type (2B)    │ Length (4B)   │ Payload (N bytes) │
/// │ 0x54 0x59    │ LE uint16    │ LE uint32     │ binary            │
/// └──────────────┴──────────────┴──────────────┴────────────────────┘
/// ```
public enum WireFormat {
    /// Magic bytes: ASCII "TY".
    public static let magic: (UInt8, UInt8) = (0x54, 0x59)

    /// Frame header size in bytes (magic 2 + type 2 + length 4).
    public static let headerSize = 8

    /// Maximum payload size: 1 MB.
    public static let maxPayloadSize: UInt32 = 1_048_576
}

/// Errors that can occur during frame encoding/decoding.
public enum WireFormatError: Error, Sendable {
    case invalidMagic(UInt8, UInt8)
    case payloadTooLarge(size: UInt32)
    case unknownServerMessageType(UInt16)
    case unknownClientMessageType(UInt16)
}

/// A raw frame read from the wire (header already validated).
public struct RawFrame: Sendable {
    /// Message type code from the frame header.
    public let typeCode: UInt16
    /// Payload bytes (without header).
    public let payload: [UInt8]

    public init(typeCode: UInt16, payload: [UInt8]) {
        self.typeCode = typeCode
        self.payload = payload
    }
}

// MARK: - Frame Encoding

extension WireFormat {
    /// Encode a `ServerMessage` into a complete frame (header + payload).
    public static func encodeServerMessage(_ message: ServerMessage) -> [UInt8] {
        var encoder = BinaryEncoder()
        encoder.writeServerMessage(message)
        return buildFrame(typeCode: message.typeCode.rawValue, payload: encoder.data)
    }

    /// Encode a `ClientMessage` into a complete frame (header + payload).
    public static func encodeClientMessage(_ message: ClientMessage) -> [UInt8] {
        var encoder = BinaryEncoder()
        encoder.writeClientMessage(message)
        return buildFrame(typeCode: message.typeCode.rawValue, payload: encoder.data)
    }

    /// Build a raw frame from type code and payload bytes.
    static func buildFrame(typeCode: UInt16, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = []
        frame.reserveCapacity(headerSize + payload.count)
        // Magic
        frame.append(magic.0)
        frame.append(magic.1)
        // Type (LE)
        withUnsafeBytes(of: typeCode.littleEndian) { frame.append(contentsOf: $0) }
        // Length (LE)
        let length = UInt32(payload.count)
        withUnsafeBytes(of: length.littleEndian) { frame.append(contentsOf: $0) }
        // Payload
        frame.append(contentsOf: payload)
        return frame
    }
}

// MARK: - Frame Decoding

extension WireFormat {
    /// Parse the frame header from raw bytes.
    /// Returns `(typeCode, payloadLength)` or throws on invalid magic.
    public static func parseHeader(_ header: [UInt8]) throws -> (typeCode: UInt16, payloadLength: UInt32) {
        precondition(header.count >= headerSize)

        // Validate magic
        guard header[0] == magic.0, header[1] == magic.1 else {
            throw WireFormatError.invalidMagic(header[0], header[1])
        }

        // Type code (LE)
        let typeCode = UInt16(header[2]) | (UInt16(header[3]) << 8)

        // Payload length (LE)
        let payloadLength = UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24)

        guard payloadLength <= maxPayloadSize else {
            throw WireFormatError.payloadTooLarge(size: payloadLength)
        }

        return (typeCode, payloadLength)
    }

    /// Decode a `ServerMessage` from a raw frame.
    public static func decodeServerMessage(_ frame: RawFrame) throws -> ServerMessage {
        guard let msgType = ServerMessageType(rawValue: frame.typeCode) else {
            throw WireFormatError.unknownServerMessageType(frame.typeCode)
        }
        var decoder = BinaryDecoder(frame.payload)
        return try decoder.readServerMessage(type: msgType)
    }

    /// Decode a `ClientMessage` from a raw frame.
    public static func decodeClientMessage(_ frame: RawFrame) throws -> ClientMessage {
        guard let msgType = ClientMessageType(rawValue: frame.typeCode) else {
            throw WireFormatError.unknownClientMessageType(frame.typeCode)
        }
        var decoder = BinaryDecoder(frame.payload)
        return try decoder.readClientMessage(type: msgType)
    }
}
