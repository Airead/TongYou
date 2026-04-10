import CoreGraphics
import CoreText
import Metal

/// Cached glyph information stored per character.
struct GlyphInfo {
    /// Position in atlas texture (physical pixels).
    let atlasX: UInt32
    let atlasY: UInt32
    /// Rasterized glyph size in atlas (physical pixels).
    let width: UInt32
    let height: UInt32
    /// Bearing offsets from cell origin (physical pixels).
    /// offset_x: left edge of cell to left edge of glyph bbox.
    /// offset_y: top of cell (baseline - ascent region) to top of glyph bbox.
    let bearingX: Int16
    let bearingY: Int16
}

/// Cache entry wrapping GlyphInfo with LRU tracking.
struct GlyphEntry {
    var info: GlyphInfo
    var lastUsedFrame: UInt64
}

/// Grayscale glyph texture atlas using shelf (row) packing.
///
/// Design (informed by Ghostty):
/// - R8Unorm single-channel texture for text glyphs
/// - 1px border around the atlas to prevent sampling artifacts
/// - Shelf-packing: rows filled left-to-right, row height = tallest glyph in that row
/// - Doubles texture size when full, copies existing data
final class GlyphAtlas {

    private let device: MTLDevice
    private let grayscaleColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
    private(set) var texture: MTLTexture
    private(set) var textureSize: UInt32

    private var cache: [Unicode.Scalar: GlyphEntry] = [:]

    // Shelf packing state
    private var shelfX: UInt32 = 1       // current x in active shelf (1px border)
    private var shelfY: UInt32 = 1       // current shelf top y (1px border)
    private var shelfHeight: UInt32 = 0  // tallest glyph in current shelf

    /// Whether the atlas texture has been modified since last GPU sync.
    private(set) var isDirty = false

    /// Number of active (non-evicted) entries.
    var activeEntryCount: Int { cache.count }

    private static let evictionTriggerRatio: Double = 0.75

    private let maxTextureSize: UInt32

    init(device: MTLDevice, initialSize: UInt32 = 1024, maxTextureSize: UInt32 = 8192) {
        self.device = device
        self.maxTextureSize = maxTextureSize
        self.textureSize = initialSize
        self.texture = Self.createTexture(device: device, size: initialSize)
    }

    /// Clear the dirty flag after GPU has consumed the updated texture.
    func clearDirty() {
        isDirty = false
    }

    /// Reset the atlas, clearing all cached glyphs. Used when font changes.
    func reset() {
        cache.removeAll(keepingCapacity: true)
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        texture = Self.createTexture(device: device, size: textureSize)
        isDirty = true
    }

    // MARK: - Glyph Lookup / Rasterization

    /// Get or rasterize a glyph. Resolves the font via FontSystem fallback on cache miss.
    /// The `frameNumber` is used for LRU tracking.
    func getOrRasterize(
        character: Unicode.Scalar,
        fontSystem: FontSystem,
        frameNumber: UInt64 = 0
    ) -> GlyphInfo? {
        if let entry = cache[character] {
            // Only update LRU timestamp when stale (avoids dictionary write on every hit)
            if frameNumber &- entry.lastUsedFrame > 60 {
                cache[character] = GlyphEntry(info: entry.info, lastUsedFrame: frameNumber)
            }
            return entry.info
        }

        let font = fontSystem.fontForCharacter(character)
        guard let info = rasterizeGlyph(character: character, font: font, fontSystem: fontSystem) else {
            return nil
        }
        cache[character] = GlyphEntry(info: info, lastUsedFrame: frameNumber)
        return info
    }

    // MARK: - Private: Rasterization

    private func rasterizeGlyph(
        character: Unicode.Scalar,
        font: CTFont,
        fontSystem: FontSystem
    ) -> GlyphInfo? {
        guard var glyph = fontSystem.glyphForCharacter(character, in: font) else {
            return nil
        }

        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &boundingRect, 1)

        if boundingRect.width < 0.5 && boundingRect.height < 0.5 {
            return GlyphInfo(atlasX: 0, atlasY: 0, width: 0, height: 0,
                             bearingX: 0, bearingY: 0)
        }

        let bearingXf = boundingRect.origin.x
        let bearingYf = boundingRect.origin.y

        let pxX = floor(bearingXf)
        let pxY = floor(bearingYf)
        let fracX = bearingXf - pxX
        let fracY = bearingYf - pxY

        let canvasWidth = UInt32(ceil(boundingRect.width + fracX)) + 1  // +1 for rasterization padding
        let canvasHeight = UInt32(ceil(boundingRect.height + fracY)) + 1

        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        guard let region = reserveRegion(width: canvasWidth, height: canvasHeight) else {
            return nil
        }

        let bytesPerRow = Int(canvasWidth)
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * Int(canvasHeight))

        guard let context = CGContext(
            data: &pixelData,
            width: Int(canvasWidth),
            height: Int(canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: grayscaleColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        // CRITICAL: Disable subpixel quantization — we manage positioning manually
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)

        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

        // CGContext origin is bottom-left: translate by fractional offset + negated bbox origin
        context.textMatrix = .identity
        let drawX = fracX - boundingRect.origin.x
        let drawY = fracY - boundingRect.origin.y
        var position = CGPoint(x: drawX, y: drawY)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)

        let mtlRegion = MTLRegion(
            origin: MTLOrigin(x: Int(region.x), y: Int(region.y), z: 0),
            size: MTLSize(width: Int(canvasWidth), height: Int(canvasHeight), depth: 1)
        )
        texture.replace(region: mtlRegion, mipmapLevel: 0,
                        withBytes: pixelData, bytesPerRow: bytesPerRow)
        isDirty = true

        // bearingY in top-down coords: baseline - pxY - canvasHeight
        let baselineF = CGFloat(fontSystem.baseline) + fontSystem.baselineFractionalOffset
        let bearingYFromTop = Int16(baselineF - pxY - CGFloat(canvasHeight))

        let info = GlyphInfo(
            atlasX: region.x,
            atlasY: region.y,
            width: canvasWidth,
            height: canvasHeight,
            bearingX: Int16(pxX),
            bearingY: bearingYFromTop
        )
        return info
    }

    // MARK: - Shelf Packing

    private struct AtlasRegion {
        let x: UInt32
        let y: UInt32
    }

    /// Reserve a rectangular region in the atlas. Grows texture if needed.
    private func reserveRegion(width: UInt32, height: UInt32) -> AtlasRegion? {
        // Try to fit in current shelf
        let borderPadding: UInt32 = 1
        let maxCoord = textureSize - borderPadding

        if shelfX + width <= maxCoord && shelfY + height <= maxCoord {
            let region = AtlasRegion(x: shelfX, y: shelfY)
            shelfX += width + borderPadding
            shelfHeight = max(shelfHeight, height)
            return region
        }

        // Move to next shelf
        let newShelfY = shelfY + shelfHeight + borderPadding
        if borderPadding + width <= maxCoord && newShelfY + height <= maxCoord {
            shelfX = borderPadding
            shelfY = newShelfY
            shelfHeight = height
            let region = AtlasRegion(x: shelfX, y: shelfY)
            shelfX += width + borderPadding
            return region
        }

        // Atlas full — grow
        guard grow() else { return nil }
        return reserveRegion(width: width, height: height)
    }

    private func grow() -> Bool {
        let newSize = textureSize * 2
        guard newSize <= maxTextureSize else { return false }

        let newTexture = Self.createTexture(device: device, size: newSize)

        let oldSize = Int(textureSize)
        var pixelData = [UInt8](repeating: 0, count: oldSize * oldSize)
        texture.getBytes(
            &pixelData,
            bytesPerRow: oldSize,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0
        )
        newTexture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: oldSize, height: oldSize, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: oldSize
        )

        texture = newTexture
        textureSize = newSize
        isDirty = true
        return true
    }

    // MARK: - LRU Eviction

    /// Check atlas utilization and evict stale entries if needed.
    /// Call once per frame after all glyphs have been looked up.
    func evictIfNeeded(frameNumber: UInt64, fontSystem: FontSystem) {
        guard cache.count > 0 else { return }
        // Utilization = used shelf area / total texture area
        let usedArea = Double(shelfY + shelfHeight) * Double(textureSize)
        let totalArea = Double(textureSize) * Double(textureSize)
        guard usedArea / totalArea > Self.evictionTriggerRatio else { return }

        // Evict oldest 25% of cache entries
        let evictCount = max(1, cache.count / 4)
        let sorted = cache.sorted { $0.value.lastUsedFrame < $1.value.lastUsedFrame }
        for i in 0..<evictCount {
            cache.removeValue(forKey: sorted[i].key)
        }

        // Always compact after eviction to reclaim atlas space
        compact(fontSystem: fontSystem, frameNumber: frameNumber)
    }

    /// Rebuild the atlas from scratch with only active cache entries.
    private func compact(fontSystem: FontSystem, frameNumber: UInt64) {
        let activeEntries = cache

        shelfX = 1
        shelfY = 1
        shelfHeight = 0

        let newSize = compactTextureSize(entryCount: activeEntries.count)
        texture = Self.createTexture(device: device, size: newSize)
        textureSize = newSize
        cache.removeAll(keepingCapacity: true)

        for (scalar, entry) in activeEntries {
            let font = fontSystem.fontForCharacter(scalar)
            if let info = rasterizeGlyph(character: scalar, font: font, fontSystem: fontSystem) {
                cache[scalar] = GlyphEntry(info: info, lastUsedFrame: entry.lastUsedFrame)
            }
        }

        isDirty = true
    }

    /// Choose smallest power-of-two texture size that fits the given entry count.
    private func compactTextureSize(entryCount: Int) -> UInt32 {
        // Estimate needed area: entryCount * average glyph area * 1.5 headroom
        let avgGlyphArea: Double = 17.0 * 21.0
        let neededArea = Double(entryCount) * avgGlyphArea * 1.5
        var size: UInt32 = 1024
        while Double(size * size) < neededArea && size < maxTextureSize {
            size *= 2
        }
        return size
    }

    // MARK: - Texture Creation

    private static func createTexture(device: MTLDevice, size: UInt32) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(size),
            height: Int(size),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create atlas texture \(size)x\(size)")
        }
        return texture
    }
}

