import Testing
import Metal
@testable import TongYou

struct GlyphAtlasTests {

    private func makeAtlas(size: UInt32 = 512, maxSize: UInt32 = 8192) -> (GlyphAtlas, FontSystem)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        let atlas = GlyphAtlas(device: device, initialSize: size, maxTextureSize: maxSize)
        return (atlas, fontSystem)
    }

    @Test func atlasInitialState() {
        guard let (atlas, _) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        #expect(atlas.textureSize == 512)
        #expect(atlas.texture.pixelFormat == .r8Unorm)
        #expect(atlas.isDirty == false)
    }

    @Test func rasterizeAsciiGlyph() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let info = atlas.getOrRasterize(
            character: "A", fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
        #expect(info!.atlasX >= 1)  // 1px border
        #expect(info!.atlasY >= 1)
        #expect(atlas.isDirty == true)
    }

    @Test func cacheHitReturnsSameInfo() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let info1 = atlas.getOrRasterize(
            character: "B", fontSystem: fontSystem
        )
        atlas.clearDirty()
        let info2 = atlas.getOrRasterize(
            character: "B", fontSystem: fontSystem
        )
        #expect(info1 != nil)
        #expect(info2 != nil)
        #expect(info1!.atlasX == info2!.atlasX)
        #expect(info1!.atlasY == info2!.atlasY)
        // Cache hit should not dirty the atlas
        #expect(atlas.isDirty == false)
    }

    @Test func multipleGlyphsPackedSequentially() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let chars: [Unicode.Scalar] = ["A", "B", "C", "D"]
        var infos: [GlyphInfo] = []
        for ch in chars {
            if let info = atlas.getOrRasterize(
                character: ch, fontSystem: fontSystem
            ) {
                infos.append(info)
            }
        }
        #expect(infos.count == 4)
        // All should be on the same shelf (row) if they fit
        // atlasY should be the same for all
        let firstY = infos[0].atlasY
        for info in infos {
            #expect(info.atlasY == firstY)
        }
        // atlasX should be increasing
        for i in 1..<infos.count {
            #expect(infos[i].atlasX > infos[i - 1].atlasX)
        }
    }

    @Test func spaceGlyphHasZeroSize() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let info = atlas.getOrRasterize(
            character: " ", fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width == 0)
        #expect(info!.height == 0)
    }

    @Test func atlasGrowsWhenFull() {
        guard let (atlas, fontSystem) = makeAtlas(size: 64) else {
            Issue.record("Metal device not available")
            return
        }
        // Rasterize many characters to force atlas growth
        let chars: [Unicode.Scalar] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").map {
            $0.unicodeScalars.first!
        }
        for ch in chars {
            _ = atlas.getOrRasterize(
                character: ch, fontSystem: fontSystem
            )
        }
        // Atlas should have grown from 64
        #expect(atlas.textureSize > 64)
    }

    @Test func lruFrameNumberUpdatedOnHit() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        // First access at frame 1
        atlas.advanceFrame()
        _ = atlas.getOrRasterize(character: "A", fontSystem: fontSystem)
        let countAfterFirst = atlas.activeEntryCount
        #expect(countAfterFirst == 1)

        // Advance several frames, access again — should still be 1 entry (cache hit)
        for _ in 0..<9 { atlas.advanceFrame() }
        _ = atlas.getOrRasterize(character: "A", fontSystem: fontSystem)
        #expect(atlas.activeEntryCount == 1)
    }

    @Test func evictionRemovesStaleEntries() {
        // Cap atlas at 256px so it fills up quickly with CJK characters
        guard let (atlas, fontSystem) = makeAtlas(size: 128, maxSize: 256) else {
            Issue.record("Metal device not available")
            return
        }

        // CJK characters from U+4E00 to fill the atlas past 75%
        var chars: [Unicode.Scalar] = []
        for v: UInt32 in 0x4E00..<0x4E00 + 200 {
            if let s = Unicode.Scalar(v) { chars.append(s) }
        }
        for ch in chars {
            atlas.advanceFrame()
            _ = atlas.getOrRasterize(character: ch, fontSystem: fontSystem)
        }
        let countBefore = atlas.activeEntryCount

        atlas.advanceFrame()
        atlas.evictIfNeeded(fontSystem: fontSystem)
        let countAfter = atlas.activeEntryCount

        // Some entries should have been evicted
        #expect(countAfter < countBefore)
    }

    @Test func evictionKeepsRecentlyUsedEntries() {
        guard let (atlas, fontSystem) = makeAtlas(size: 128, maxSize: 256) else {
            Issue.record("Metal device not available")
            return
        }

        // Old CJK glyphs at early frames
        var oldChars: [Unicode.Scalar] = []
        for v: UInt32 in 0x4E00..<0x4E00 + 150 {
            if let s = Unicode.Scalar(v) { oldChars.append(s) }
        }
        // Recent ASCII glyphs at later frames
        let newChars: [Unicode.Scalar] = Array("abcdefghij").map { $0.unicodeScalars.first! }

        for ch in oldChars {
            _ = atlas.getOrRasterize(character: ch, fontSystem: fontSystem)
        }
        // Jump ahead 100 frames so recent chars have much higher frameNumber
        for _ in 0..<100 { atlas.advanceFrame() }
        for ch in newChars {
            _ = atlas.getOrRasterize(character: ch, fontSystem: fontSystem)
        }

        atlas.advanceFrame()
        atlas.evictIfNeeded(fontSystem: fontSystem)

        // Recent ASCII glyphs should survive eviction
        atlas.advanceFrame()
        let recentInfo = atlas.getOrRasterize(character: "a", fontSystem: fontSystem)
        #expect(recentInfo != nil)
    }

    @Test func rasterizeByGlyphAndFont() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let font = fontSystem.ctFont
        guard let glyph = fontSystem.glyphForCharacter("C", in: font) else {
            Issue.record("Font does not support character C")
            return
        }
        let info = atlas.getOrRasterize(
            glyph: glyph, font: font, fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
    }

    @Test func glyphBasedCacheHitReturnsSameInfo() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let font = fontSystem.ctFont
        guard let glyph = fontSystem.glyphForCharacter("D", in: font) else {
            Issue.record("Font does not support character D")
            return
        }
        let info1 = atlas.getOrRasterize(
            glyph: glyph, font: font, fontSystem: fontSystem
        )
        atlas.clearDirty()
        let info2 = atlas.getOrRasterize(
            glyph: glyph, font: font, fontSystem: fontSystem
        )
        #expect(info1 != nil)
        #expect(info2 != nil)
        #expect(info1!.atlasX == info2!.atlasX)
        #expect(info1!.atlasY == info2!.atlasY)
        #expect(atlas.isDirty == false)
    }
}
