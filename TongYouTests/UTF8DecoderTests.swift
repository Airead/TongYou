import Testing
@testable import TongYou

@Suite struct UTF8DecoderTests {

    /// Helper: decode a byte array and collect scalars.
    private func decode(_ decoder: inout UTF8Decoder, _ bytes: [UInt8]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        bytes.withUnsafeBufferPointer { buf in
            decoder.decode(buf) { result.append($0) }
        }
        return result
    }

    @Test func asciiBytes() {
        var decoder = UTF8Decoder()
        let result = decode(&decoder, [0x48, 0x65, 0x6C, 0x6C, 0x6F])  // "Hello"
        #expect(result == Array("Hello").compactMap(\.unicodeScalars.first))
    }

    @Test func twoByteSequence() {
        var decoder = UTF8Decoder()
        // "é" = U+00E9 = [0xC3, 0xA9]
        let result = decode(&decoder, [0xC3, 0xA9])
        #expect(result == [Unicode.Scalar(0x00E9)!])
    }

    @Test func threeByteSequence() {
        var decoder = UTF8Decoder()
        // "你" = U+4F60 = [0xE4, 0xBD, 0xA0]
        let result = decode(&decoder, [0xE4, 0xBD, 0xA0])
        #expect(result == [Unicode.Scalar(0x4F60)!])
    }

    @Test func fourByteSequence() {
        var decoder = UTF8Decoder()
        // "😀" = U+1F600 = [0xF0, 0x9F, 0x98, 0x80]
        let result = decode(&decoder, [0xF0, 0x9F, 0x98, 0x80])
        #expect(result == [Unicode.Scalar(0x1F600)!])
    }

    @Test func splitThreeByteAcrossChunks() {
        var decoder = UTF8Decoder()
        // "你" split: first byte in chunk 1, remaining in chunk 2
        let chunk1 = decode(&decoder, [0xE4])
        #expect(chunk1.isEmpty)
        let chunk2 = decode(&decoder, [0xBD, 0xA0])
        #expect(chunk2 == [Unicode.Scalar(0x4F60)!])
    }

    @Test func splitThreeByteOneByteAtATime() {
        var decoder = UTF8Decoder()
        let r1 = decode(&decoder, [0xE4])
        #expect(r1.isEmpty)
        let r2 = decode(&decoder, [0xBD])
        #expect(r2.isEmpty)
        let r3 = decode(&decoder, [0xA0])
        #expect(r3 == [Unicode.Scalar(0x4F60)!])
    }

    @Test func mixedAsciiAndMultiByte() {
        var decoder = UTF8Decoder()
        // "Hi你" = [0x48, 0x69, 0xE4, 0xBD, 0xA0]
        let result = decode(&decoder, [0x48, 0x69, 0xE4, 0xBD, 0xA0])
        #expect(result == [
            Unicode.Scalar(0x48)!, // H
            Unicode.Scalar(0x69)!, // i
            Unicode.Scalar(0x4F60)! // 你
        ])
    }

    @Test func mixedSplitAtBoundary() {
        var decoder = UTF8Decoder()
        // "Hi你" split between ASCII and CJK first byte
        let chunk1 = decode(&decoder, [0x48, 0x69, 0xE4])
        #expect(chunk1 == [Unicode.Scalar(0x48)!, Unicode.Scalar(0x69)!])
        let chunk2 = decode(&decoder, [0xBD, 0xA0])
        #expect(chunk2 == [Unicode.Scalar(0x4F60)!])
    }

    @Test func invalidLeadingByte() {
        var decoder = UTF8Decoder()
        // 0xFF is never valid in UTF-8
        let result = decode(&decoder, [0xFF, 0x41])
        let replacement = Unicode.Scalar(0xFFFD)!
        #expect(result == [replacement, Unicode.Scalar(0x41)!])
    }

    @Test func invalidContinuationByte() {
        var decoder = UTF8Decoder()
        // Start a 2-byte sequence but follow with a non-continuation byte
        let result = decode(&decoder, [0xC3, 0x41])  // 0xC3 expects continuation, gets 'A'
        let replacement = Unicode.Scalar(0xFFFD)!
        #expect(result == [replacement, Unicode.Scalar(0x41)!])
    }

    @Test func overlongTwoByteSequence() {
        var decoder = UTF8Decoder()
        // Overlong encoding of U+0000: [0xC0, 0x80]
        let result = decode(&decoder, [0xC0, 0x80])
        let replacement = Unicode.Scalar(0xFFFD)!
        #expect(result == [replacement])
    }

    @Test func standaloneContiunationByte() {
        var decoder = UTF8Decoder()
        // 0x80 is a continuation byte without a leading byte
        let result = decode(&decoder, [0x80, 0x41])
        let replacement = Unicode.Scalar(0xFFFD)!
        #expect(result == [replacement, Unicode.Scalar(0x41)!])
    }

    @Test func emptyInput() {
        var decoder = UTF8Decoder()
        let result = decode(&decoder, [])
        #expect(result.isEmpty)
    }

    @Test func reset() {
        var decoder = UTF8Decoder()
        // Start a multi-byte sequence
        _ = decode(&decoder, [0xE4])
        // Reset discards pending state
        decoder.reset()
        // Now decode a fresh ASCII byte
        let result = decode(&decoder, [0x41])
        #expect(result == [Unicode.Scalar(0x41)!])
    }
}
