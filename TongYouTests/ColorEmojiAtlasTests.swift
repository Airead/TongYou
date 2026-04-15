import Testing
import Metal
import TYTerminal
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
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem, frameNumber: 1)
        let countAfterFirst = atlas.activeEntryCount
        #expect(countAfterFirst == 1)

        // Second access at frame 10 — should still be 1 entry (cache hit)
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem, frameNumber: 10)
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
        guard let (atlas, fontSystem) = makeAtlas(size: 128, maxSize: 256) else {
            Issue.record("Metal device not available")
            return
        }

        // Fill atlas with many emojis, including larger ZWJ sequences
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

        for (i, cluster) in emojis.enumerated() {
            _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem, frameNumber: UInt64(i))
        }

        let countBefore = atlas.activeEntryCount
        atlas.evictIfNeeded(frameNumber: UInt64(emojis.count), fontSystem: fontSystem)
        let countAfter = atlas.activeEntryCount

        // Some entries should have been evicted
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

    @Test func getReturnsNilOnCacheMiss() {
        guard let (atlas, _) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🚀"))
        let info = atlas.get(cluster: cluster)
        #expect(info == nil)
        #expect(atlas.isDirty == false)
    }

    @Test func getReturnsInfoAfterSyncRasterize() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🎸"))
        _ = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
        atlas.clearDirty()

        let info = atlas.get(cluster: cluster)
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
        #expect(atlas.isDirty == false)
    }

    @Test func asyncRasterizationFillsCacheAndIncrementsModified() async throws {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🎹"))
        let initialModified = atlas.modified

        await withCheckedContinuation { continuation in
            atlas.enqueueRasterization(cluster: cluster, fontSystem: fontSystem) {
                continuation.resume()
            }
        }

        let info = atlas.get(cluster: cluster)
        #expect(info != nil)
        #expect(info!.width > 0)
        #expect(info!.height > 0)
        #expect(atlas.isDirty == true)
        #expect(atlas.modified > initialModified)
    }

    @Test func asyncRasterizationDeduplicatesPendingWork() async throws {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("🎺"))

        var completionCount = 0
        await withCheckedContinuation { continuation in
            atlas.enqueueRasterization(cluster: cluster, fontSystem: fontSystem) {
                completionCount += 1
                continuation.resume()
            }
            atlas.enqueueRasterization(cluster: cluster, fontSystem: fontSystem) {
                completionCount += 1
            }
        }

        #expect(completionCount == 2)
        #expect(atlas.get(cluster: cluster) != nil)
    }

    @Test func nonEmojiGetReturnsNilAndDoesNotEnqueue() {
        guard let (atlas, fontSystem) = makeAtlas() else {
            Issue.record("Metal device not available")
            return
        }
        let cluster = GraphemeCluster(Character("A"))
        let info = atlas.get(cluster: cluster)
        #expect(info == nil)

        var completionCalled = false
        atlas.enqueueRasterization(cluster: cluster, fontSystem: fontSystem) {
            completionCalled = true
        }
        #expect(completionCalled == true)
        #expect(atlas.isDirty == false)
    }
}
