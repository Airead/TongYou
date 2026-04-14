import CoreText
import TYTerminal

/// A contiguous sequence of cells with the same font and style attributes.
struct TextRun: Equatable {
    let cells: [Cell]
    let startCol: Int
    let font: CTFont
    let attributes: CellAttributes
}

/// The result of shaping a text run.
struct ShapedGlyph: Equatable {
    let glyph: CGGlyph
    let position: CGPoint
    let advance: CGSize
    let cellIndex: Int
    let font: CTFont
}

/// Uses CoreText to shape runs of text into glyphs.
struct CoreTextShaper {
    let fontSystem: FontSystem

    /// Shape a text run into an array of glyphs with positions.
    /// Uses CTTypesetter with forced LTR embedding.
    func shape(_ run: TextRun) -> [ShapedGlyph] {
        let text = run.cells.map { $0.content.string }.joined()
        guard !text.isEmpty else { return [] }

        guard let attrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else {
            return []
        }
        CFAttributedStringReplaceString(attrString, CFRangeMake(0, 0), text as CFString)
        CFAttributedStringSetAttribute(
            attrString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCTFontAttributeName,
            run.font
        )

        let options = [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attrString, options) else {
            return []
        }

        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, text.utf16.count))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        // Precompute UTF-16 offset to cell index mapping.
        let utf16ToCellIndex = buildUTF16ToCellIndexMap(cells: run.cells)

        var shapedGlyphs: [ShapedGlyph] = []
        for ctrun in runs {
            let glyphCount = CTRunGetGlyphCount(ctrun)
            guard glyphCount > 0 else { continue }

            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)

            CTRunGetGlyphs(ctrun, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(ctrun, CFRangeMake(0, 0), &positions)
            CTRunGetAdvances(ctrun, CFRangeMake(0, 0), &advances)
            CTRunGetStringIndices(ctrun, CFRangeMake(0, 0), &stringIndices)

            let runAttributes = CTRunGetAttributes(ctrun) as? [CFString: Any] ?? [:]
            let runFont: CTFont
            if let fontValue = runAttributes[kCTFontAttributeName] {
                runFont = fontValue as! CTFont
            } else {
                runFont = run.font
            }

            for i in 0..<glyphCount {
                let stringIdx = stringIndices[i]
                let cellIndex = utf16ToCellIndex[stringIdx]

                shapedGlyphs.append(ShapedGlyph(
                    glyph: glyphs[i],
                    position: positions[i],
                    advance: advances[i],
                    cellIndex: cellIndex,
                    font: runFont
                ))
            }
        }

        return shapedGlyphs
    }

    /// Build a mapping from UTF-16 string index to cell index within the run.
    private func buildUTF16ToCellIndexMap(cells: [Cell]) -> [Int] {
        var totalUTF16 = 0
        for cell in cells {
            totalUTF16 += cell.content.string.utf16.count
        }
        var map = [Int](repeating: 0, count: totalUTF16)
        var utf16Offset = 0
        for (i, cell) in cells.enumerated() {
            let count = cell.content.string.utf16.count
            for o in 0..<count {
                map[utf16Offset + o] = i
            }
            utf16Offset += count
        }
        return map
    }
}
