import CoreFoundation
import Testing
@testable import TongYou

struct FontSystemTests {

    @Test func defaultFontLoads() {
        let fs = FontSystem(scaleFactor: 2.0)
        // Should load a monospace font
        #expect(fs.cellSize.width > 0)
        #expect(fs.cellSize.height > 0)
        #expect(fs.baseline > 0)
        #expect(fs.ascent > 0)
        #expect(fs.descent < 0)  // negative by convention
    }

    @Test func cellSizeIsReasonable() {
        let fs = FontSystem(pointSize: 13.0, scaleFactor: 2.0)
        // At 13pt 2x, cell width should be roughly 14-18px, height 28-40px
        #expect(fs.cellSize.width >= 10)
        #expect(fs.cellSize.width <= 30)
        #expect(fs.cellSize.height >= 20)
        #expect(fs.cellSize.height <= 60)
    }

    @Test func cellHeightContainsAscentDescentLeading() {
        let fs = FontSystem(pointSize: 13.0, scaleFactor: 2.0)
        // Cell height should be >= ascent + |descent| (may be slightly off due to rounding)
        let minHeight = fs.ascent + abs(fs.descent)
        #expect(CGFloat(fs.cellSize.height) >= minHeight - 1.0)
    }

    @Test func baselineWithinCell() {
        let fs = FontSystem(pointSize: 13.0, scaleFactor: 2.0)
        // Baseline must be within cell height
        #expect(fs.baseline > 0)
        #expect(fs.baseline < fs.cellSize.height)
    }

    @Test func scaleFactorAffectsCellSize() {
        let fs1x = FontSystem(pointSize: 13.0, scaleFactor: 1.0)
        let fs2x = FontSystem(pointSize: 13.0, scaleFactor: 2.0)
        // 2x should produce roughly double the cell size
        let widthRatio = Double(fs2x.cellSize.width) / Double(fs1x.cellSize.width)
        let heightRatio = Double(fs2x.cellSize.height) / Double(fs1x.cellSize.height)
        #expect(widthRatio > 1.5)
        #expect(widthRatio < 2.5)
        #expect(heightRatio > 1.5)
        #expect(heightRatio < 2.5)
    }

    @Test func fontFallbackForAscii() {
        let fs = FontSystem(scaleFactor: 2.0)
        // ASCII should use the primary font
        let font = fs.fontForCharacter("A")
        #expect(font === fs.ctFont)
    }

    @Test func glyphForAsciiCharacter() {
        let fs = FontSystem(scaleFactor: 2.0)
        let glyph = fs.glyphForCharacter("A", in: fs.ctFont)
        #expect(glyph != nil)
        #expect(glyph! > 0)
    }

    @Test func glyphForSpaceCharacter() {
        let fs = FontSystem(scaleFactor: 2.0)
        let glyph = fs.glyphForCharacter(" ", in: fs.ctFont)
        #expect(glyph != nil)
    }
}
