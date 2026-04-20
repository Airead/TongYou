import Foundation
import Testing
@testable import TYTerminal

@Suite("PasteEncoder tests")
struct PasteEncoderTests {

    @Test func bracketedWrapsWithMarkers() {
        let payload: [UInt8] = Array("hello\nworld".utf8)
        let out = PasteEncoder.wrap(payload, bracketed: true)

        let start = PasteEncoder.bracketStart
        let end = PasteEncoder.bracketEnd
        #expect(out.count == start.count + payload.count + end.count)
        #expect(Array(out.prefix(start.count)) == start)
        #expect(Array(out.suffix(end.count)) == end)
        // Newlines must survive untouched inside the bracketed payload so
        // vim sees them as real line breaks from the paste stream.
        let inner = Array(out.dropFirst(start.count).dropLast(end.count))
        #expect(inner == payload)
    }

    @Test func nonBracketedConvertsLFtoCR() {
        let payload: [UInt8] = [0x61, 0x0A, 0x62, 0x0A, 0x63]  // a\nb\nc
        let out = PasteEncoder.wrap(payload, bracketed: false)

        #expect(out == [0x61, 0x0D, 0x62, 0x0D, 0x63])  // a\rb\rc
    }

    @Test func nonBracketedLeavesNonNewlineBytesAlone() {
        let payload: [UInt8] = [0x01, 0x0D, 0x20, 0x7F, 0xFF]
        let out = PasteEncoder.wrap(payload, bracketed: false)
        #expect(out == payload)
    }

    @Test func emptyPayload() {
        #expect(PasteEncoder.wrap([], bracketed: false) == [])
        #expect(PasteEncoder.wrap([], bracketed: true) == PasteEncoder.bracketStart + PasteEncoder.bracketEnd)
    }

    @Test func largeBracketedPayloadPreservesNewlines() {
        // Mirrors the original bug report: ~22KB paste with many \n that
        // must reach the PTY unaltered when bracketed paste is active.
        var payload = [UInt8](repeating: 0x61, count: 22_000)
        for i in stride(from: 50, to: payload.count, by: 80) {
            payload[i] = 0x0A
        }
        let out = PasteEncoder.wrap(payload, bracketed: true)

        let start = PasteEncoder.bracketStart
        let end = PasteEncoder.bracketEnd
        let inner = Array(out.dropFirst(start.count).dropLast(end.count))
        #expect(inner == payload)
        #expect(inner.filter { $0 == 0x0A }.count == payload.filter { $0 == 0x0A }.count)
    }
}
