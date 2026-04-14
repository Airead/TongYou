#!/usr/bin/env swift

// validate_emoji_step4.swift
// Step 4: CoreText shaping metadata
// 实现 Ghostty 风格的 CTRun shaping，并输出详细元数据

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
    case ligature = "Ligature"
    case mixedComplex = "Mixed Complex"
    
    var text: String {
        switch self {
        case .simpleEmoji:
            return "😀🎉"
        case .zwjSequence:
            return "👨‍👩‍👧‍👦"
        case .skinToneModifier:
            return "👋🏻"
        case .variationSelector:
            return "❤️"
        case .flagEmoji:
            return "🇨🇳"
        case .ligature:
            return "fi"
        case .mixedComplex:
            return "Héllo👋🏻"
        }
    }
}

// MARK: - Ghostty-Style Shaper

struct GhosttyShaper {
    let baseFont: CTFont
    let fontSize: CGFloat = 48.0
    
    init() {
        self.baseFont = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
    }
    
    struct ShapedGlyph {
        let glyph: CGGlyph
        let position: CGPoint
        let advance: CGSize
        let stringIndex: CFIndex
        let fontName: String
    }
    
    struct ShapingResult {
        let glyphs: [ShapedGlyph]
        let runCount: Int
        let totalWidth: CGFloat
    }
    
    func shape(_ text: String) -> ShapingResult {
        guard let attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else {
            return ShapingResult(glyphs: [], runCount: 0, totalWidth: 0)
        }
        
        CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), text as CFString)
        CFAttributedStringSetAttribute(
            attributedString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCTFontAttributeName,
            baseFont
        )
        
        let options: [String: Any] = [
            kCTTypesetterOptionForcedEmbeddingLevel as String: 0
        ]
        
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attributedString,
            options as CFDictionary
        ) else {
            return ShapingResult(glyphs: [], runCount: 0, totalWidth: 0)
        }
        
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        
        var shapedGlyphs: [ShapedGlyph] = []
        var currentX: CGFloat = 0
        
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            
            let glyphs = UnsafeMutablePointer<CGGlyph>.allocate(capacity: glyphCount)
            let positions = UnsafeMutablePointer<CGPoint>.allocate(capacity: glyphCount)
            let advances = UnsafeMutablePointer<CGSize>.allocate(capacity: glyphCount)
            let indices = UnsafeMutablePointer<CFIndex>.allocate(capacity: glyphCount)
            
            CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), positions)
            CTRunGetAdvances(run, CFRangeMake(0, 0), advances)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), indices)
            
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let fontName = CTFontCopyPostScriptName(runFont) as String
            
            for i in 0..<glyphCount {
                shapedGlyphs.append(ShapedGlyph(
                    glyph: glyphs[i],
                    position: CGPoint(x: currentX + positions[i].x, y: positions[i].y),
                    advance: advances[i],
                    stringIndex: indices[i],
                    fontName: fontName
                ))
                currentX += advances[i].width
            }
            
            glyphs.deallocate()
            positions.deallocate()
            advances.deallocate()
            indices.deallocate()
        }
        
        return ShapingResult(glyphs: shapedGlyphs, runCount: runs.count, totalWidth: currentX)
    }
}

// MARK: - Font System (TongYou approach)

struct TongYouFontSystem {
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
    
    /// Count how many glyphs TongYou would render
    func countGlyphs(for text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let utf16 = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            if CTFontGetGlyphsForCharacters(baseFont, utf16, &glyphs, utf16.count) {
                count += 1
            } else {
                let font = fontForCharacter(scalar)
                if CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) {
                    count += 1
                }
            }
        }
        return count
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

func renderTongYouStyle(text: String, fontSystem: TongYouFontSystem, size: CGSize) -> CGImage? {
    guard let context = createContext(size: size) else { return nil }
    
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setStrokeColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
    context.stroke(CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    var currentX: CGFloat = 20
    let startY: CGFloat = size.height / 2 - fontSystem.fontSize / 2
    
    for scalar in text.unicodeScalars {
        let font = fontSystem.fontForCharacter(scalar)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: String(scalar), attributes: attrs)
        str.draw(at: NSPoint(x: currentX, y: startY))
        
        var glyph: CGGlyph = 0
        let utf16 = Array(String(scalar).utf16)
        if CTFontGetGlyphsForCharacters(font, utf16, &glyph, utf16.count) {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            currentX += advance.width.rounded()
        } else {
            currentX += fontSystem.fontSize * 0.6
        }
    }
    
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

func renderGhosttyStyle(text: String, fontSystem: TongYouFontSystem, size: CGSize) -> CGImage? {
    guard let context = createContext(size: size) else { return nil }
    
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setStrokeColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
    context.stroke(CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    let attrs: [NSAttributedString.Key: Any] = [
        .font: fontSystem.baseFont,
        .foregroundColor: NSColor.black
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    str.draw(at: NSPoint(x: 20, y: size.height / 2 - fontSystem.fontSize / 2))
    
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
    let totalHeight = size.height + 80
    
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
    NSAttributedString(string: "TongYou (per-character)", attributes: labelAttrs)
        .draw(at: NSPoint(x: 20, y: size.height + 15))
    NSAttributedString(string: "Ghostty (CoreText shaping)", attributes: labelAttrs)
        .draw(at: NSPoint(x: size.width + 40, y: size.height + 15))
    
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
print("Step 4: CoreText Shaping with Metadata")
print(String(repeating: "=", count: 70))

let fontSystem = TongYouFontSystem()
let shaper = GhosttyShaper()
let imageSize = CGSize(width: 300, height: 70)

for testCase in TestCase.allCases {
    print("\n[Test: \(testCase.rawValue)]")
    print("Text: '\(testCase.text)'")
    print("Codepoints: \(testCase.text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))")
    
    let tongyouGlyphs = fontSystem.countGlyphs(for: testCase.text)
    let result = shaper.shape(testCase.text)
    
    print("TongYou glyph count: \(tongyouGlyphs)")
    print("Ghostty glyph count: \(result.glyphs.count)")
    print("Ghostty run count: \(result.runCount)")
    print("Ghostty total width: \(String(format: "%.1f", result.totalWidth))px")
    
        if result.glyphs.count > 0 {
        print("Glyph details:")
        for (i, g) in result.glyphs.enumerated() {
            // stringIndex is UTF-16 offset
            let utf16Offset = Int(g.stringIndex)
            let idx = String.Index(utf16Offset: utf16Offset, in: testCase.text)
            let endIdx = testCase.text.index(after: idx)
            let char = String(testCase.text[idx..<endIdx])
            print("  [\(i)] glyph=\(g.glyph) pos=(\(String(format: "%.1f", g.position.x)), \(String(format: "%.1f", g.position.y))) adv=(\(String(format: "%.1f", g.advance.width)), \(String(format: "%.1f", g.advance.height))) font=\(g.fontName) char='\(char)'")
        }
    }
    
    guard let tongyouImage = renderTongYouStyle(text: testCase.text, fontSystem: fontSystem, size: imageSize),
          let ghosttyImage = renderGhosttyStyle(text: testCase.text, fontSystem: fontSystem, size: imageSize) else {
        print("  ERROR: Failed to render images")
        continue
    }
    
    if let comparison = createComparisonImage(tongyou: tongyouImage, ghostty: ghosttyImage,
                                               title: testCase.rawValue, size: imageSize) {
        let filename = "\(testCase.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_step4.png"
        savePNG(comparison, to: "\(outputDir)/\(filename)")
    }
    
    print(String(repeating: "-", count: 70))
}

print("\n✅ Step 4 complete")
print("Key insight: Ghostty reduces glyph count via shaping")
print("- ZWJ sequences: multiple scalars → 1 glyph")
print("- Ligatures: multiple scalars → 1 glyph")
print("- Images saved to: \(outputDir)/")
