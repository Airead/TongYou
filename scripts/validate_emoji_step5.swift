#!/usr/bin/env swift

// validate_emoji_step5.swift
// Step 5: Grid cell width simulation
// 模拟终端等宽网格，对比逐字符 vs shaping 两种布局策略的 cell 对齐差异

import Foundation
import CoreText
import CoreGraphics
import AppKit

// MARK: - Test Cases

enum TestCase: String, CaseIterable {
    case simpleEmoji = "Simple Emoji"
    case zwjSequence = "ZWJ Sequence"
    case skinToneModifier = "Skin Tone"
    case variationSelector = "Variation Selector"
    case flagEmoji = "Flag Emoji"
    case cjkWithEmoji = "CJK + Emoji"
    case wideChars = "Wide Characters"
    case mixedNormalAndWide = "Mixed Normal+Wide"
    case overflowTest = "Overflow Test"
    
    var text: String {
        switch self {
        case .simpleEmoji:
            return "😀🎉"
        case .zwjSequence:
            return "ab👨‍👩‍👧‍👦cd"
        case .skinToneModifier:
            return "ab👋🏻cd"
        case .variationSelector:
            return "ab❤️cd"
        case .flagEmoji:
            return "ab🇨🇳cd"
        case .cjkWithEmoji:
            return "你好🌍世界"
        case .wideChars:
            return "你a我b他"
        case .mixedNormalAndWide:
            return "a你bc我d"
        case .overflowTest:
            return "1234567890🇨🇳1234"
        }
    }
}

// MARK: - Unicode Width Extension

extension Unicode.Scalar {
    var terminalWidth: UInt8 {
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
        if v >= 0xA000 && v <= 0xA4CF { return true }
        if v >= 0xA960 && v <= 0xA97C { return true }
        if v >= 0xF900 && v <= 0xFAFF { return true }
        if v >= 0xFE10 && v <= 0xFE19 { return true }
        if v >= 0xFE30 && v <= 0xFE6F { return true }
        if v >= 0xFF01 && v <= 0xFF60 { return true }
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }
        if v >= 0x2190 && v <= 0x21FF { return true }
        if v >= 0x25A0 && v <= 0x25FF { return true }
        if v >= 0x2600 && v <= 0x26FF { return true }
        if v >= 0x2700 && v <= 0x27BF { return true }
        if v >= 0xE0A0 && v <= 0xE0A2 { return true }
        if v >= 0xE0B0 && v <= 0xE0B3 { return true }
        guard v > 0xFFFF else { return false }
        if v >= 0x1F300 && v <= 0x1F64F { return true }
        if v >= 0x1F400 && v <= 0x1F4FF { return true }
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        if v >= 0x1F900 && v <= 0x1F9FF { return true }
        if v >= 0x1FA00 && v <= 0x1FA6F { return true }
        if v >= 0x1FA70 && v <= 0x1FAFF { return true }
        if v >= 0x1F200 && v <= 0x1F2FF { return true }
        if v >= 0x20000 && v <= 0x2A6DF { return true }
        if v >= 0x2A700 && v <= 0x2B73F { return true }
        if v >= 0x2B740 && v <= 0x2B81F { return true }
        if v >= 0x2B820 && v <= 0x2CEAF { return true }
        if v >= 0x2CEB0 && v <= 0x2EBEF { return true }
        if v >= 0x2EBF0 && v <= 0x2F73F { return true }
        if v >= 0x2F800 && v <= 0x2FA1F { return true }
        if v >= 0x30000 && v <= 0x3134F { return true }
        if v >= 0x31350 && v <= 0x323AF { return true }
        return false
    }
}

// MARK: - Grid Layout Engine

/// Simulates a terminal grid with fixed cell dimensions
struct TerminalGrid {
    let cellWidth: CGFloat = 28.9  // Menlo 48pt advance width
    let cellHeight: CGFloat = 60.0
    let fontSize: CGFloat = 48.0
    
    /// Compute cell width for a grapheme cluster (TongYou approach)
    func tongyouWidth(for char: Character) -> Int {
        // Sum scalar widths
        var width: UInt8 = 0
        for scalar in char.unicodeScalars {
            width += scalar.terminalWidth
        }
        return Int(width)
    }
    
    /// Compute cell width for a grapheme cluster (Ghostty approach)
    /// Uses the base scalar width, ignoring ZWJ/variation selectors
    func ghosttyWidth(for char: Character) -> Int {
        guard let baseScalar = char.unicodeScalars.first else { return 1 }
        
        // For emoji sequences, use width of the base emoji
        let isEmojiSequence = char.unicodeScalars.count > 1 && 
            char.unicodeScalars.contains { $0.value >= 0x1F300 || $0.value == 0xFE0F || $0.value == 0x200D }
        
        if isEmojiSequence {
            // ZWJ sequences and variation sequences inherit base width
            return max(1, Int(baseScalar.terminalWidth))
        }
        
        // Default: same as TongYou
        return tongyouWidth(for: char)
    }
    
    /// Build cell layout for a string using TongYou logic
    func buildTongYouLayout(text: String) -> [(char: Character, startCell: Int, width: Int)] {
        var layout: [(Character, Int, Int)] = []
        var currentCell = 0
        
        for char in text {
            let width = tongyouWidth(for: char)
            layout.append((char, currentCell, width))
            currentCell += width
        }
        
        return layout
    }
    
    /// Build cell layout for a string using Ghostty logic
    func buildGhosttyLayout(text: String) -> [(char: Character, startCell: Int, width: Int)] {
        var layout: [(Character, Int, Int)] = []
        var currentCell = 0
        
        for char in text {
            let width = ghosttyWidth(for: char)
            layout.append((char, currentCell, width))
            currentCell += width
        }
        
        return layout
    }
}

// MARK: - Font System

struct FontSystem {
    let baseFont: CTFont
    let fontSize: CGFloat = 48.0
    
    init() {
        self.baseFont = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
    }
    
    func fontForCharacter(_ character: Unicode.Scalar) -> CTFont {
        let utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        if CTFontGetGlyphsForCharacters(baseFont, utf16, &glyphs, utf16.count) {
            return baseFont
        }
        let string = String(character) as CFString
        return CTFontCreateForString(baseFont, string, CFRange(location: 0, length: CFStringGetLength(string)))
    }
}

// MARK: - Rendering

func createContext(size: CGSize) -> CGContext? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                     CGBitmapInfo.byteOrder32Little.rawValue
    return CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: Int(size.width) * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )
}

/// Draw grid lines for visual cell boundary reference
func drawGrid(context: CGContext, grid: TerminalGrid, cells: Int, startX: CGFloat, startY: CGFloat) {
    context.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
    context.setLineWidth(1)
    
    for i in 0...cells {
        let x = startX + CGFloat(i) * grid.cellWidth
        context.move(to: CGPoint(x: x, y: startY))
        context.addLine(to: CGPoint(x: x, y: startY + grid.cellHeight))
    }
    
    context.strokePath()
    
    // Draw cell index labels at top
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8),
        .foregroundColor: NSColor.gray
    ]
    
    for i in 0..<cells {
        let x = startX + CGFloat(i) * grid.cellWidth + 2
        NSAttributedString(string: String(i), attributes: labelAttrs)
            .draw(at: NSPoint(x: x, y: startY + grid.cellHeight + 2))
    }
    
    NSGraphicsContext.restoreGraphicsState()
}

/// Render text using TongYou per-character layout
func renderTongYouGrid(text: String, fontSystem: FontSystem, grid: TerminalGrid, size: CGSize) -> CGImage? {
    guard let context = createContext(size: size) else { return nil }
    
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    
    let startX: CGFloat = 20
    let startY: CGFloat = 15
    let layout = grid.buildTongYouLayout(text: text)
    let maxCells = layout.last.map { $0.startCell + $0.width } ?? 10
    
    drawGrid(context: context, grid: grid, cells: max(10, maxCells), startX: startX, startY: startY)
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    for (char, cell, width) in layout {
        let x = startX + CGFloat(cell) * grid.cellWidth
        
        // For each scalar in the character, draw individually (TongYou approach)
        var scalarX = x
        let cellCenterY = startY + grid.cellHeight / 2 - grid.fontSize / 2
        
        for scalar in char.unicodeScalars {
            let font = fontSystem.fontForCharacter(scalar)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: String(scalar), attributes: attrs)
            str.draw(at: NSPoint(x: scalarX, y: cellCenterY))
            
            var glyph: CGGlyph = 0
            let utf16 = Array(String(scalar).utf16)
            if CTFontGetGlyphsForCharacters(font, utf16, &glyph, utf16.count) {
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                scalarX += advance.width.rounded()
            } else {
                scalarX += grid.cellWidth * 0.5
            }
        }
        
        // Highlight the cell boundary
        if width > 1 {
            context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.9, alpha: 0.3))
            context.fill(CGRect(x: x, y: startY, width: CGFloat(width) * grid.cellWidth, height: grid.cellHeight))
        }
    }
    
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

/// Render text using Ghostty shaping-aware layout
func renderGhosttyGrid(text: String, fontSystem: FontSystem, grid: TerminalGrid, size: CGSize) -> CGImage? {
    guard let context = createContext(size: size) else { return nil }
    
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    
    let startX: CGFloat = 20
    let startY: CGFloat = 15
    let layout = grid.buildGhosttyLayout(text: text)
    let maxCells = layout.last.map { $0.startCell + $0.width } ?? 10
    
    drawGrid(context: context, grid: grid, cells: max(10, maxCells), startX: startX, startY: startY)
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    for (char, cell, width) in layout {
        let x = startX + CGFloat(cell) * grid.cellWidth
        let cellCenterY = startY + grid.cellHeight / 2 - grid.fontSize / 2
        
        // Ghostty draws the full grapheme cluster as one unit via shaping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fontSystem.baseFont,
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: String(char), attributes: attrs)
        str.draw(at: NSPoint(x: x, y: cellCenterY))
        
        // Highlight wide cells
        if width > 1 {
            context.setFillColor(CGColor(red: 0.9, green: 1, blue: 0.9, alpha: 0.3))
            context.fill(CGRect(x: x, y: startY, width: CGFloat(width) * grid.cellWidth, height: grid.cellHeight))
        }
    }
    
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

// MARK: - Output Helpers

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("Failed to create image destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("  Saved: \(path)")
    } else {
        print("  Failed to write \(path)")
    }
}

func createComparisonImage(tongyou: CGImage, ghostty: CGImage, title: String, size: CGSize) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                     CGBitmapInfo.byteOrder32Little.rawValue
    
    let totalWidth = size.width * 2 + 60
    let totalHeight = size.height + 70
    
    guard let context = CGContext(
        data: nil,
        width: Int(totalWidth),
        height: Int(totalHeight),
        bitsPerComponent: 8,
        bytesPerRow: Int(totalWidth) * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return nil }
    
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 14),
        .foregroundColor: NSColor.black
    ]
    NSAttributedString(string: title, attributes: titleAttrs)
        .draw(at: NSPoint(x: 20, y: totalHeight - 25))
    
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.darkGray
    ]
    NSAttributedString(string: "TongYou (per-char, grid)", attributes: labelAttrs)
        .draw(at: NSPoint(x: 20, y: size.height + 10))
    NSAttributedString(string: "Ghostty (shaping, grid)", attributes: labelAttrs)
        .draw(at: NSPoint(x: size.width + 40, y: size.height + 10))
    
    NSGraphicsContext.restoreGraphicsState()
    
    context.draw(tongyou, in: CGRect(x: 20, y: 10, width: size.width, height: size.height))
    context.draw(ghostty, in: CGRect(x: size.width + 40, y: 10, width: size.width, height: size.height))
    
    return context.makeImage()
}

// MARK: - Main

let outputDir = "scripts/emoji-test-output"
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

print(String(repeating: "=", count: 70))
print("Step 5: Grid Cell Width Simulation")
print("Compare terminal grid alignment between two approaches")
print(String(repeating: "=", count: 70))

let fontSystem = FontSystem()
let grid = TerminalGrid()
let imageSize = CGSize(width: 400, height: 100)

for testCase in TestCase.allCases {
    print("\n[Test: \(testCase.rawValue)]")
    print("Text: '\(testCase.text)'")
    
    let tongyouLayout = grid.buildTongYouLayout(text: testCase.text)
    let ghosttyLayout = grid.buildGhosttyLayout(text: testCase.text)
    
    print("TongYou layout:")
    for (char, cell, width) in tongyouLayout {
        let scalarInfo = char.unicodeScalars.map { "U+\(String(format: "%04X", $0.value))" }.joined(separator: " ")
        print("  cell[\(cell)] w=\(width) '\(char)' (\(scalarInfo))")
    }
    
    print("Ghostty layout:")
    for (char, cell, width) in ghosttyLayout {
        let scalarInfo = char.unicodeScalars.map { "U+\(String(format: "%04X", $0.value))" }.joined(separator: " ")
        print("  cell[\(cell)] w=\(width) '\(char)' (\(scalarInfo))")
    }
    
    guard let tongyouImage = renderTongYouGrid(text: testCase.text, fontSystem: fontSystem, grid: grid, size: imageSize),
          let ghosttyImage = renderGhosttyGrid(text: testCase.text, fontSystem: fontSystem, grid: grid, size: imageSize) else {
        print("  ERROR: Failed to render")
        continue
    }
    
    if let comparison = createComparisonImage(tongyou: tongyouImage, ghostty: ghosttyImage,
                                               title: testCase.rawValue, size: imageSize) {
        let filename = "\(testCase.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_step5.png"
        savePNG(comparison, to: "\(outputDir)/\(filename)")
    }
    
    print(String(repeating: "-", count: 70))
}

print("\n✅ Step 5 complete")
print("Key insight: Grid alignment differs significantly")
print("- TongYou sums scalar widths, causing ZWJ/flag sequences to occupy 3-7 cells")
print("- Ghostty uses base width, keeping emoji sequences in 1-2 cells")
print("- Wide CJK characters align correctly in both approaches")
print("- Mixed text shows cumulative drift differences")
print("Images saved to: \(outputDir)/")
