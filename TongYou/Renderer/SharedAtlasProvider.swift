import Metal

/// App-level singleton that holds shared GlyphAtlas and ColorEmojiAtlas instances.
/// All MetalRenderers reference the same atlases, avoiding duplicate GPU texture memory.
final class SharedAtlasProvider {
    static let shared = SharedAtlasProvider()

    let glyphAtlas: GlyphAtlas
    let emojiAtlas: ColorEmojiAtlas

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available")
        }
        self.glyphAtlas = GlyphAtlas(device: device)
        self.emojiAtlas = ColorEmojiAtlas(device: device)
    }
}
