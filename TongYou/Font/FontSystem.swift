import CoreText
import Foundation
import TYTerminal

/// Font system built on CoreText.
/// Loads a monospace font, computes integer cell metrics, and provides font fallback.
///
/// All metric calculations follow the Ghostty approach:
/// - `round()` for cell dimensions (±0.5px error, better than ceil)
/// - Baseline centered vertically in the pixel-rounded cell
/// - Subpixel fractional offsets tracked separately from integer bearings
final class FontSystem {

    /// The primary CTFont at the requested point size (scaled for backing factor).
    let ctFont: CTFont

    /// Cell dimensions in physical pixels (integer).
    let cellSize: CellSize

    /// Distance from cell top to text baseline, in physical pixels (integer).
    let baseline: UInt32

    /// Fractional vertical offset for centering face in pixel-rounded cell.
    /// Applied as CGContext translation during rasterization.
    let baselineFractionalOffset: CGFloat

    /// Font ascent in physical pixels (float, for glyph positioning).
    let ascent: CGFloat

    /// Font descent in physical pixels (float, negative value).
    let descent: CGFloat

    /// Font leading (line gap) in physical pixels (float).
    let leading: CGFloat

    /// Backing scale factor (e.g. 2.0 for Retina).
    let scaleFactor: CGFloat

    /// Point size used to create the font.
    let pointSize: CGFloat

    private lazy var codepointResolver: CodepointResolver = {
        var fontCollection = FontCollection()
        fontCollection.addFont(self.ctFont, style: .regular)
        let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, self.pointSize * self.scaleFactor, nil)
        return CodepointResolver(
            collection: fontCollection,
            baseFont: self.ctFont,
            emojiFont: emojiFont,
            fontSystem: self
        )
    }()

    init(fontName: String? = nil, pointSize: CGFloat = 13.0, scaleFactor: CGFloat = 2.0) {
        self.pointSize = pointSize
        self.scaleFactor = scaleFactor

        let scaledSize = pointSize * scaleFactor

        func systemMonospace() -> CTFont {
            CTFontCreateUIFontForLanguage(.userFixedPitch, scaledSize, nil)
                ?? CTFontCreateWithName("Menlo" as CFString, scaledSize, nil)
        }

        let font: CTFont
        if let name = fontName {
            let candidate = CTFontCreateWithName(name as CFString, scaledSize, nil)
            // Verify CoreText didn't silently substitute a different font
            let actualName = CTFontCopyPostScriptName(candidate) as String
            if actualName.lowercased().contains(name.lowercased().replacingOccurrences(of: " ", with: ""))
                || (CTFontCopyFamilyName(candidate) as String).lowercased() == name.lowercased() {
                font = candidate
            } else {
                font = systemMonospace()
            }
        } else {
            font = systemMonospace()
        }
        self.ctFont = font

        let rawAscent = CTFontGetAscent(font)
        let rawDescent = CTFontGetDescent(font)  // positive value from CoreText
        let rawLeading = CTFontGetLeading(font)

        self.ascent = rawAscent
        self.descent = -rawDescent  // store as negative (conventional)
        self.leading = rawLeading

        let cellWidth: UInt32
        var glyph: CGGlyph = 0
        var advances = CGSize.zero
        let chars: [UniChar] = [0x004D]  // 'M' — reliable monospace reference
        CTFontGetGlyphsForCharacters(font, chars, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advances, 1)
        cellWidth = UInt32(advances.width.rounded())

        // face height = ascent + descent + leading (descent is positive from CoreText)
        let faceHeight = rawAscent + rawDescent + rawLeading
        let cellHeight = UInt32(faceHeight.rounded())

        self.cellSize = CellSize(width: max(1, cellWidth), height: max(1, cellHeight))

        // Baseline centering: split line gap evenly, center face in pixel-rounded cell
        let halfLeading = rawLeading / 2.0
        let cellHeightF = CGFloat(cellHeight)
        let verticalOffset = (cellHeightF - faceHeight) / 2.0
        let baselineFromTop = verticalOffset + rawAscent + halfLeading
        let baselineRounded = UInt32(baselineFromTop.rounded())

        self.baseline = baselineRounded
        self.baselineFractionalOffset = baselineFromTop - CGFloat(baselineRounded)
    }

    func fontForCharacter(_ character: Unicode.Scalar) -> CTFont {
        let cluster = GraphemeCluster(character)
        return codepointResolver.resolveFont(for: cluster, style: .regular)
    }

    func font(for cluster: GraphemeCluster, attributes: CellAttributes) -> CTFont {
        let style = FontCollection.Style.from(attributes: attributes)
        return codepointResolver.resolveFont(for: cluster, style: style)
    }

    func glyphForCharacter(_ character: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
        let utf16 = Array(Character(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else {
            return nil
        }
        return glyphs[0]
    }

    func canRender(_ cluster: GraphemeCluster, in font: CTFont) -> Bool {
        let utf16 = Array(cluster.string.utf16)
        guard !utf16.isEmpty else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
    }
}


