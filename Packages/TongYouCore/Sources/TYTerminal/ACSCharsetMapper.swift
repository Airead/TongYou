import Foundation

/// DEC Special Graphics (VT100 ACS) mapping.
public struct ACSCharsetMapper: Sendable {
    public enum Slot: Sendable {
        case g0, g1
    }

    public enum Set: Sendable {
        case ascii
        case decSpecial
    }

    /// Standard DEC Special Graphics to Unicode mapping.
    /// https://en.wikipedia.org/wiki/DEC_Special_Graphics
    public static let decSpecialMap: [UInt8: Unicode.Scalar] = [
        0x60: Unicode.Scalar(0x25C6)!, // ` -> ◆
        0x61: Unicode.Scalar(0x2592)!, // a -> ▒
        0x62: Unicode.Scalar(0x2409)!, // b -> ␉
        0x63: Unicode.Scalar(0x240C)!, // c -> ␌
        0x64: Unicode.Scalar(0x240D)!, // d -> ␍
        0x65: Unicode.Scalar(0x240A)!, // e -> ␊
        0x66: Unicode.Scalar(0x00B0)!, // f -> °
        0x67: Unicode.Scalar(0x00B1)!, // g -> ±
        0x68: Unicode.Scalar(0x2424)!, // h -> ␤
        0x69: Unicode.Scalar(0x240B)!, // i -> ␋
        0x6A: Unicode.Scalar(0x2518)!, // j -> ┘
        0x6B: Unicode.Scalar(0x2510)!, // k -> ┐
        0x6C: Unicode.Scalar(0x250C)!, // l -> ┌
        0x6D: Unicode.Scalar(0x2514)!, // m -> └
        0x6E: Unicode.Scalar(0x253C)!, // n -> ┼
        0x6F: Unicode.Scalar(0x23BA)!, // o -> ⎺
        0x70: Unicode.Scalar(0x23BB)!, // p -> ⎻
        0x71: Unicode.Scalar(0x2500)!, // q -> ─
        0x72: Unicode.Scalar(0x23BC)!, // r -> ⎼
        0x73: Unicode.Scalar(0x23BD)!, // s -> ⎽
        0x74: Unicode.Scalar(0x251C)!, // t -> ├
        0x75: Unicode.Scalar(0x2524)!, // u -> ┤
        0x76: Unicode.Scalar(0x2534)!, // v -> ┴
        0x77: Unicode.Scalar(0x252C)!, // w -> ┬
        0x78: Unicode.Scalar(0x2502)!, // x -> │
        0x79: Unicode.Scalar(0x2264)!, // y -> ≤
        0x7A: Unicode.Scalar(0x2265)!, // z -> ≥
        0x7B: Unicode.Scalar(0x03C0)!, // { -> π
        0x7C: Unicode.Scalar(0x2260)!, // | -> ≠
        0x7D: Unicode.Scalar(0x00A3)!, // } -> £
        0x7E: Unicode.Scalar(0x00B7)!, // ~ -> ·
    ]

    public static func map(_ byte: UInt8, charset: Set) -> Unicode.Scalar {
        guard charset == .decSpecial, let mapped = decSpecialMap[byte] else {
            return Unicode.Scalar(byte)
        }
        return mapped
    }
}

/// Charset state managing G0/G1 slots and the active GL bank.
public struct CharsetState: Sendable, Equatable {
    public var g0: ACSCharsetMapper.Set = .ascii
    public var g1: ACSCharsetMapper.Set = .ascii
    public var gl: ACSCharsetMapper.Slot = .g0

    public init() {}

    public mutating func configure(slot: ACSCharsetMapper.Slot, set: ACSCharsetMapper.Set) {
        switch slot {
        case .g0: g0 = set
        case .g1: g1 = set
        }
    }

    public mutating func invokeGL(_ slot: ACSCharsetMapper.Slot) {
        gl = slot
    }

    public func map(_ byte: UInt8) -> Unicode.Scalar {
        let set = (gl == .g0) ? g0 : g1
        return ACSCharsetMapper.map(byte, charset: set)
    }
}
