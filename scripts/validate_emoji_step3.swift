#!/usr/bin/env swift

// validate_emoji_step3.swift
// Step 3: Simple rendering comparison
// 使用 NSAttributedString 简单绘制，对比逐字符 vs 整体 shaping

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
    
    var text: String {
        switch self {
        case .simpleEmoji:
            return "😀🎉🚀"
        case .zwjSequence:
            return "👨‍👩‍👧‍👦"
        case .skinToneModifier:
            return "👋🏻"
        case .variationSelector:
            return "❤️❤︎"
        case .flagEmoji:
            return "🇨🇳"
        }
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

/// Render each scalar separately (simulates TongYou)
func renderTongYouStyle(text: String, fontSystem: FontSystem, size: CGSize) -> CGImage? {
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

/// Render as whole string (simulates Ghostty shaping)
func renderGhosttyStyle(text: String, fontSystem: FontSystem, size: CGSize) -> CGImage? {
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

// MARK: - Output

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
    NSAttributedString(string: "Ghostty (whole-string)", attributes: labelAttrs)
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

print(String(repeating: "=", count: 60))
print("Step 3: Simple Rendering Comparison")
print(String(repeating: "=", count: 60))

let fontSystem = FontSystem()
let imageSize = CGSize(width: 300, height: 70)

for testCase in TestCase.allCases {
    print("\nRendering: \(testCase.rawValue)")
    print("Text: '\(testCase.text)'")
    print("Scalars: \(testCase.text.unicodeScalars.count)")
    
    guard let tongyouImage = renderTongYouStyle(text: testCase.text, fontSystem: fontSystem, size: imageSize),
          let ghosttyImage = renderGhosttyStyle(text: testCase.text, fontSystem: fontSystem, size: imageSize) else {
        print("  ERROR: Failed to render")
        continue
    }
    
    if let comparison = createComparisonImage(tongyou: tongyouImage, ghostty: ghosttyImage,
                                               title: testCase.rawValue, size: imageSize) {
        let filename = "\(testCase.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_step3.png"
        savePNG(comparison, to: "\(outputDir)/\(filename)")
    }
}

print("\n✅ Step 3 complete")
print("Check comparison images in: \(outputDir)/")
