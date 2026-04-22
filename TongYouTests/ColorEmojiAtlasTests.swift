import Testing
import Metal
@testable import TongYou

struct ColorEmojiAtlasTests {

    private func makeAtlas(size: UInt32 = 512, maxSize: UInt32 = 4096) -> (ColorEmojiAtlas, FontSystem)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fontSystem = FontSystem(scaleFactor: 2.0)
        let atlas = ColorEmojiAtlas(device: device, initialSize: size, maxTextureSize: maxSize)
        return (atlas, fontSystem)
    }

    @Test func atlasInitialState() {
        guard let (atlas, _) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        #expect(atlas.textureSize == 512)
        #expect(atlas.texture.pixelFormat == .bgra8Unorm)
        #expect(atlas.isDirty == false)
    }

    @Test func rasterizeSingleEmoji() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("😀"))
        let info = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
        #expect(info!.atlasX >= 1)  // 1px border
        #expect(info!.atlasY >= 1)
        #expect(atlas.isDirty == true)
    }

    @Test func nonEmojiReturnsNil() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("A"))
        let info = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        #expect(info == nil)
        #expect(atlas.isDirty == false)
    }

    @Test func zwjEmojiSequence() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        // Family emoji: 👨‍👩‍👧‍👦
        let cluster = GraphemeCluster(Character("👨‍👩‍👧‍👦"))
        #expect(cluster.isEmojiSequence == true)
        #expect(cluster.scalarCount == 7)

        let info = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
    }

    @Test func skinToneModifier() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        // Wave with light skin tone: 👋🏻
        let cluster = GraphemeCluster(Character("👋🏻"))
        #expect(cluster.isEmojiSequence == true)
        #expect(cluster.scalarCount == 2)

        let info = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
    }

    @Test func flagEmoji() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        // China flag: 🇨🇳
        let cluster = GraphemeCluster(Character("🇨🇳"))
        #expect(cluster.isEmojiSequence == true)
        #expect(cluster.scalarCount == 2)

        let info = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
    }

    @Test func cacheHitReturnsSameInfo() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🎉"))

        let info1 = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )
        atlas.clearDirty()
        let info2 = atlas.getOrRasterize(
            cluster: cluster, fontSystem: fontSystem
        )

        #expect(info1 != nil)
        #expect(info2 != nil)
        #expect(info1!.atlasX == info2!.atlasX)
        #expect(info1!.atlasY == info2!.atlasY)
        // Cache hit should not dirty the atlas
        #expect(atlas.isDirty == false)
    }

    @Test func multipleEmojisPackedSequentially() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let emojis = ["😀", "😎", "🎉", "🚀"].map { GraphemeCluster(Character($0)) }
        var infos: [EmojiGlyphInfo] = []

        for cluster in emojis {
            if let info = atlas.getOrRasterize(
                cluster: cluster, fontSystem: fontSystem
            ) {
                infos.append(info)
            }
        }

        #expect(infos.count == 4)
        // All should be on the same shelf (row) if they fit
        let firstY = infos[0].atlasY
        for info in infos {
            #expect(info.atlasY == firstY)
        }
        // atlasX should be increasing
        for i in 1..<infos.count {
            #expect(infos[i].atlasX > infos[i - 1].atlasX)
        }
    }

    @Test func lruFrameNumberUpdatedOnHit() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🎯"))

        // First access at frame 1
        atlas.advanceFrame()
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
        let countAfterFirst = atlas.activeEntryCount
        #expect(countAfterFirst == 1)

        // Advance several frames, access again — should still be 1 entry (cache hit)
        for _ in 0..<9 { atlas.advanceFrame() }
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
        #expect(atlas.activeEntryCount == 1)
    }

    @Test func atlasGrowsWhenFull() {
        guard let (atlas, fontSystem) = makeAtlas(size: 128) else {
            Issue.record("Metal device not available")
            return
        }

        // Rasterize many emojis to force atlas growth, including larger ZWJ sequences
        let emojis: [GraphemeCluster] = [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇",
            "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚",
            "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥸",
            "🤩", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️",
            "😣", "😖", "😫", "😩", "🥺", "😢", "😭", "😤", "😠", "😡",
            "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓",
            "🤗", "🤔", "🤭", "🤫", "🤥", "😶", "😐", "😑", "😬", "🙄",
            "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵",
            "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠",
        ].map { GraphemeCluster(Character($0)) }

        for cluster in emojis {
            _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
        }

        // Atlas should have grown from 128
        #expect(atlas.textureSize > 128)
    }

    @Test func evictionRemovesStaleEntries() {
        // Let the atlas grow so it exercises the 0.75 grow-trigger
        // (the 0.95 at-max trigger requires very dense packing that's
        // hard to hit with our fixed emoji set). Emoji sizes vary with
        // font metrics — fill one-per-frame and stop the moment
        // evictIfNeeded fires, then verify some entries were dropped.
        guard let (atlas, fontSystem) = makeAtlas(size: 128, maxSize: 1024) else {
            Issue.record("Metal device not available")
            return
        }

        let emojis: [GraphemeCluster] = [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇",
            "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚",
            "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥸",
            "🤩", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️",
            "😣", "😖", "😫", "😩", "🥺", "😢", "😭", "😤", "😠", "😡",
            "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓",
            "🤗", "🤔", "🤭", "🤫", "🤥", "😶", "😐", "😑", "😬", "🙄",
            "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵",
            "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠",
        ].map { GraphemeCluster(Character($0)) }

        var countBefore = 0
        var countAfter = 0
        var evictionFired = false
        for cluster in emojis {
            atlas.advanceFrame()
            _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
            let before = atlas.activeEntryCount
            atlas.advanceFrame()
            if atlas.evictIfNeeded(fontSystem: fontSystem) {
                countBefore = before
                countAfter = atlas.activeEntryCount
                evictionFired = true
                break
            }
        }

        #expect(evictionFired)
        #expect(countAfter < countBefore)
    }

    @Test func resetClearsAllEntries() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }

        let cluster = GraphemeCluster(Character("🔥"))
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
        #expect(atlas.activeEntryCount == 1)
        #expect(atlas.isDirty == true)

        atlas.clearDirty()
        atlas.reset()

        #expect(atlas.activeEntryCount == 0)
        #expect(atlas.isDirty == true)
    }
}
