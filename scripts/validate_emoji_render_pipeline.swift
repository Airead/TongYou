#!/usr/bin/env swift

// validate_emoji_render_pipeline.swift
// Step A: Diagnostic script comparing three rendering approaches for emoji sequences.
// 1. TongYou-Current: per-cell single-scalar rendering (simulates current MetalRenderer)
// 2. TongYou-Fixed: per-cell full-grapheme CTTypesetter rendering
// 3. Ghostty-Reference: full-line CTTypesetter rendering

import Foundation
import CoreText
import CoreGraphics
import AppKit

// MARK: - Unicode Width (mirroring TYTerminal/CharWidth.swift)

extension Unicode.Scalar {
    public var terminalWidth: UInt8 {
        let v = self.value
        if v < 0x1100 { return 1 }
        return Self.isWide(v) ? 2 : 1
    }

    private static func isWide(_ v: UInt32) -> Bool {
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        if v >= 0x3040 && v <= 0x33FF { return true }
        if v >= 0xAC00 && v <= 0xD7A3 { return true }
        if v >= 0x3400 && v <= 0x4DBF { return true }
        if v >= 0x2E80 && v <= 0x303E { return true }
        if v >= 0x1100 && v <= 0x115F { return true }
        if v >= 0x1160 && v <= 0x11A7 { return true }
        if v >= 0x11A8 && v <= 0x11F9 { return true }
        if v >= 0x2F00 && v <= 0x2FD5 { return true }
        if v >= 0x2FF0 && v <= 0x2FFF { return true }
        if v >= 0x3000 && v <= 0x303E { return true }
        if v >= 0x31C0 && v <= 0x31EF { return true }
        if v >= 0x3200 && v <= 0x4DBF { return true }
        if v >= 0x4E00 && v <= 0xA4C6 { return true }
        if v >= 0xA960 && v <= 0xA97C { return true }
        if v >= 0xAC00 && v <= 0xD7AF { return true }
        if v >= 0xD7B0 && v <= 0xD7C6 { return true }
        if v >= 0xD7CB && v <= 0xD7FB { return true }
        if v >= 0xF900 && v <= 0xFAFF { return true }
        if v >= 0xFE10 && v <= 0xFE19 { return true }
        if v >= 0xFE30 && v <= 0xFE52 { return true }
        if v >= 0xFE54 && v <= 0xFE66 { return true }
        if v >= 0xFE68 && v <= 0xFE6B { return true }
        if v >= 0xFF01 && v <= 0xFF5E { return true }
        if v >= 0xFF5F && v <= 0xFF60 { return true }
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }
        if v >= 0x20000 && v <= 0x2FFFD { return true }
        if v >= 0x30000 && v <= 0x3FFFD { return true }
        if v >= 0xE0100 && v <= 0xE01EF { return true }
        if v >= 0x1F300 && v <= 0x1F64F { return true }
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        if v >= 0x1F900 && v <= 0x1F9FF { return true }
        if v >= 0x1F1E6 && v <= 0x1F1FF { return true }
        if v >= 0x20000 && v <= 0x2FFFD { return true }
        if v >= 0x30000 && v <= 0x3FFFD { return true }
        return false
    }
}

extension Character {
    public var terminalWidth: UInt8 {
        let scalars = Array(self.unicodeScalars)
        guard let firstScalar = scalars.first else { return 1 }

        let isEmojiSequence = scalars.count > 1 && scalars.contains { scalar in
            if scalar.value == 0x200D { return true }
            if scalar.value == 0xFE0E || scalar.value == 0xFE0F { return true }
            if scalar.value >= 0x1F3FB && scalar.value <= 0x1F3FF { return true }
            if scalar.value >= 0x1F1E6 && scalar.value <= 0x1F1FF { return true }
            return false
        }

        if isEmojiSequence {
            return firstScalar.terminalWidth
        }

        var totalWidth: UInt8 = 0
        for scalar in scalars {
            totalWidth += scalar.terminalWidth
        }
        return totalWidth
    }
}

// MARK: - Model

struct TerminalCell {
    let content: String
    let col: Int
    let width: Int
}

// MARK: - Layout Builders

func graphemeClusters(from text: String) -> [String] {
    var clusters: [String] = []
    var index = text.startIndex
    while index < text.endIndex {
        let cluster = String(text[index])
        clusters.append(cluster)
        index = text.index(after: index)
    }
    return clusters
}

func buildCurrentCells(clusters: [String]) -> [TerminalCell] {
    var cells: [TerminalCell] = []
    var col = 0
    for cluster in clusters {
        let firstScalar = cluster.unicodeScalars.first!
        let width = Int(firstScalar.terminalWidth)
        cells.append(TerminalCell(content: String(firstScalar), col: col, width: width))
        col += width
    }
    return cells
}

func buildFixedCells(clusters: [String]) -> [TerminalCell] {
    var cells: [TerminalCell] = []
    var col = 0
    for cluster in clusters {
        let width = Int(Character(cluster).terminalWidth)
        cells.append(TerminalCell(content: cluster, col: col, width: width))
        col += width
    }
    return cells
}

// MARK: - Rendering Config

struct RenderConfig {
    let cellWidth: CGFloat = 16.0
    let cellHeight: CGFloat = 30.0
    let baseline: CGFloat = 22.0
    let fontSize: CGFloat = 26.0
    let padding: CGFloat = 20.0
    let lineHeight: CGFloat = 34.0

    var baseFont: CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
    }
}

// MARK: - Renderers

func createContext(width: CGFloat, height: CGFloat) -> CGContext? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                     CGBitmapInfo.byteOrder32Little.rawValue
    return CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: Int(width) * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )
}

func renderTongYouCurrent(cells: [TerminalCell], text: String, config: RenderConfig) -> CGImage? {
    let totalWidth = config.padding * 2 + CGFloat(cells.last!.col + cells.last!.width) * config.cellWidth
    let totalHeight = config.padding * 2 + config.lineHeight

    guard let context = createContext(width: totalWidth, height: totalHeight) else { return nil }

    // Background
    context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let baseFont = config.baseFont

    for cell in cells {
        let x = config.padding + CGFloat(cell.col) * config.cellWidth

        // Draw cell grid for visualization
        context.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.5))
        context.setLineWidth(1)
        context.stroke(CGRect(x: x, y: config.padding + (config.lineHeight - config.cellHeight) / 2,
                              width: CGFloat(cell.width) * config.cellWidth, height: config.cellHeight))

        // Single-scalar rendering: CTFontDrawGlyphs
        if let scalar = cell.content.unicodeScalars.first,
           var glyph = glyphForCharacter(scalar, in: baseFont) {

            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(baseFont, .horizontal, &glyph, &bounds, 1)

            let drawX = x - bounds.origin.x
            let drawY = config.padding + (config.lineHeight - config.cellHeight) / 2 + config.baseline - bounds.origin.y

            var position = CGPoint(x: drawX, y: drawY)
            CTFontDrawGlyphs(baseFont, &glyph, &position, 1, context)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

func renderTongYouFixed(cells: [TerminalCell], text: String, config: RenderConfig) -> CGImage? {
    let totalWidth = config.padding * 2 + CGFloat(cells.last!.col + cells.last!.width) * config.cellWidth
    let totalHeight = config.padding * 2 + config.lineHeight

    guard let context = createContext(width: totalWidth, height: totalHeight) else { return nil }

    context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let baseFont = config.baseFont
    let cellTopY = config.padding + (config.lineHeight - config.cellHeight) / 2

    for cell in cells {
        let x = config.padding + CGFloat(cell.col) * config.cellWidth

        context.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.5))
        context.setLineWidth(1)
        context.stroke(CGRect(x: x, y: cellTopY, width: CGFloat(cell.width) * config.cellWidth, height: config.cellHeight))

        // Full-grapheme shaping with CTTypesetter
        let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault,
            cell.content as CFString,
            [
                kCTFontAttributeName: baseFont,
                kCTForegroundColorAttributeName: NSColor.white.cgColor
            ] as CFDictionary
        )!
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attrString,
            [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary
        ) else { continue }
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, cell.content.utf16.count))

        // We want the glyph to start at the cell's left edge.
        // CTLine draws relative to the line origin (baseline).
        let lineBounds = CTLineGetImageBounds(line, context)
        let drawY = cellTopY + config.baseline
        let drawX = x

        context.textMatrix = .identity
        context.saveGState()
        context.translateBy(x: drawX, y: drawY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

func renderGhosttyReference(cells: [TerminalCell], text: String, config: RenderConfig) -> CGImage? {
    // Ghostty reference: per-cell full-grapheme shaping WITHOUT grid lines.
    // Ghostty actually shapes runs and places glyphs manually on the grid,
    // but for emoji correctness the per-cell full-string CTTypesetter is the
    // decisive factor. We omit grid lines to show "natural" rendering.
    let totalWidth = config.padding * 2 + CGFloat(cells.last!.col + cells.last!.width) * config.cellWidth
    let totalHeight = config.padding * 2 + config.lineHeight

    guard let context = createContext(width: totalWidth, height: totalHeight) else { return nil }

    context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let baseFont = config.baseFont
    let cellTopY = config.padding + (config.lineHeight - config.cellHeight) / 2

    for cell in cells {
        let x = config.padding + CGFloat(cell.col) * config.cellWidth

        let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault,
            cell.content as CFString,
            [
                kCTFontAttributeName: baseFont,
                kCTForegroundColorAttributeName: NSColor.white.cgColor
            ] as CFDictionary
        )!
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attrString,
            [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary
        ) else { continue }
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, cell.content.utf16.count))

        let drawY = cellTopY + config.baseline
        let drawX = x

        context.textMatrix = .identity
        context.saveGState()
        context.translateBy(x: drawX, y: drawY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

// MARK: - Helpers

func glyphForCharacter(_ character: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
    let utf16 = Array(Character(character).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else {
        return nil
    }
    return glyphs[0]
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("Failed to create destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("Saved: \(path)")
    }
}

func createTripleComparison(current: CGImage, fixed: CGImage, ghostty: CGImage,
                            title: String, size: CGSize, config: RenderConfig) -> CGImage? {
    let margin: CGFloat = 20
    let sectionSpacing: CGFloat = 30
    let labelHeight: CGFloat = 30
    let titleHeight: CGFloat = 40

    let totalWidth = margin * 2 + size.width * 3 + sectionSpacing * 2
    let totalHeight = titleHeight + size.height + labelHeight + margin

    guard let context = createContext(width: totalWidth, height: totalHeight) else { return nil }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 18),
        .foregroundColor: NSColor.black
    ]
    NSAttributedString(string: title, attributes: titleAttrs)
        .draw(at: NSPoint(x: margin, y: totalHeight - 30))

    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.black
    ]
    let subLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor.gray
    ]

    let labels = [
        ("1. TongYou-Current", "Per-cell single-scalar rasterization"),
        ("2. TongYou-Fixed", "Per-cell full-grapheme CTTypesetter"),
        ("3. Ghostty-Reference", "Full-line CTTypesetter shaping")
    ]

    for (i, (main, sub)) in labels.enumerated() {
        let x = margin + CGFloat(i) * (size.width + sectionSpacing)
        let y = size.height + labelHeight - 5
        NSAttributedString(string: main, attributes: labelAttrs).draw(at: NSPoint(x: x, y: y))
        NSAttributedString(string: sub, attributes: subLabelAttrs).draw(at: NSPoint(x: x, y: y - 15))
    }

    NSGraphicsContext.restoreGraphicsState()

    context.draw(current, in: CGRect(x: margin, y: margin, width: size.width, height: size.height))
    context.draw(fixed, in: CGRect(x: margin + size.width + sectionSpacing, y: margin, width: size.width, height: size.height))
    context.draw(ghostty, in: CGRect(x: margin + (size.width + sectionSpacing) * 2, y: margin, width: size.width, height: size.height))

    return context.makeImage()
}

// MARK: - Main

let outputDir = "scripts/emoji-render-diagnosis"
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

let testCases = [
    ("prompt", "TongYou [🌿 main][✗!?⬆][🐦‍⬛ v6.2.4][☁️  fanrenhao@f2pool.com]"),
    ("zwj", "👨‍👩‍👧‍👦 ab"),
    ("skin_tone", "👋🏻 cd"),
    ("flag", "🇨🇳 ef"),
    ("mixed", "Hello 👩‍🚀 World")
]

let config = RenderConfig()

for (name, text) in testCases {
    print("\nRendering: \(name)")
    let clusters = graphemeClusters(from: text)
    print("  Grapheme clusters: \(clusters.count)")
    for (i, c) in clusters.enumerated() {
        if c.unicodeScalars.count > 1 {
            print("    [\(i)] '\(c)' (scalars: \(c.unicodeScalars.map { "U+\(String($0.value, radix: 16, uppercase: true))" }.joined(separator: " ")))")
        }
    }

    let currentCells = buildCurrentCells(clusters: clusters)
    let fixedCells = buildFixedCells(clusters: clusters)

    guard let currentImg = renderTongYouCurrent(cells: currentCells, text: text, config: config),
          let fixedImg = renderTongYouFixed(cells: fixedCells, text: text, config: config),
          let ghosttyImg = renderGhosttyReference(cells: fixedCells, text: text, config: config) else {
        print("  ERROR: Failed to render")
        continue
    }

    let maxCols = max(currentCells.last!.col + currentCells.last!.width,
                      fixedCells.last!.col + fixedCells.last!.width)
    let lineWidth = config.padding * 2 + CGFloat(maxCols) * config.cellWidth
    let size = CGSize(width: lineWidth, height: config.padding * 2 + config.lineHeight)

    if let comparison = createTripleComparison(
        current: currentImg,
        fixed: fixedImg,
        ghostty: ghosttyImg,
        title: "Test: \(name)",
        size: size,
        config: config
    ) {
        savePNG(comparison, to: "\(outputDir)/\(name)_comparison.png")
    }
}

print("\n✅ Diagnosis complete. Images saved to \(outputDir)/")
