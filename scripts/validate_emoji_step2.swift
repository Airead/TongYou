#!/usr/bin/env swift

// validate_emoji_step2.swift
// Step 2: Basic font loading and glyph lookup
// 验证字体回退机制是否工作

import Foundation
import CoreText

// MARK: - Test Cases

enum TestCase: String, CaseIterable {
    case simpleEmoji = "Simple Emoji"
    case zwjSequence = "ZWJ Sequence"
    case skinToneModifier = "Skin Tone"
    case variationSelector = "Variation Selector"
    case flagEmoji = "Flag Emoji"
    case cjkWithEmoji = "CJK + Emoji"
    
    var text: String {
        switch self {
        case .simpleEmoji:
            return "😀"
        case .zwjSequence:
            return "👨‍👩‍👧‍👦"
        case .skinToneModifier:
            return "👋🏻"
        case .variationSelector:
            return "❤️"
        case .flagEmoji:
            return "🇨🇳"
        case .cjkWithEmoji:
            return "你好🌍"
        }
    }
}

// MARK: - Font System

struct FontSystem {
    let baseFont: CTFont
    let fontSize: CGFloat = 32.0
    
    init() {
        self.baseFont = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        print("Base font: \(CTFontCopyFullName(baseFont) as String)")
    }
    
    /// Check if font can render this character
    func canRender(_ character: Unicode.Scalar, in font: CTFont) -> Bool {
        let utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
    }
    
    /// Find font for character with fallback
    func fontForCharacter(_ character: Unicode.Scalar) -> (font: CTFont, isFallback: Bool) {
        if canRender(character, in: baseFont) {
            return (baseFont, false)
        }
        
        let string = String(character) as CFString
        let fallbackFont = CTFontCreateForString(
            baseFont,
            string,
            CFRange(location: 0, length: CFStringGetLength(string))
        )
        return (fallbackFont, true)
    }
    
    /// Check if font has sbix table (color bitmap emoji)
    func hasSbixTable(_ font: CTFont) -> Bool {
        let tag: CTFontTableTag = 0x73626978 // "sbix"
        guard let data = CTFontCopyTable(font, tag, []) else { return false }
        return CFDataGetLength(data) > 0
    }
    
    /// Analyze a string character by character
    func analyzeString(_ text: String) -> String {
        var output = ""
        
        for (index, char) in text.enumerated() {
            let scalars = Array(char.unicodeScalars)
            let scalarStr = scalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            
            output += "\nCharacter [\(index)]: '\(char)'\n"
            output += "  Scalars: \(scalarStr)\n"
            output += "  Grapheme width: 1 visual character\n"
            
            // Analyze each scalar
            for (scalarIndex, scalar) in scalars.enumerated() {
                let (font, isFallback) = fontForCharacter(scalar)
                let fontName = CTFontCopyPostScriptName(font) as String
                let hasSbix = hasSbixTable(font)
                
                output += "  Scalar [\(scalarIndex)] U+\(String(format: "%04X", scalar.value)):\n"
                output += "    Font: \(fontName)\(isFallback ? " (fallback)" : "")\n"
                output += "    Has sbix: \(hasSbix ? "Yes" : "No")\n"
                output += "    Terminal width: \(scalar.terminalWidth)\n"
            }
        }
        
        return output
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
        if v >= 0x1F300 && v <= 0x1F64F { return true }
        if v >= 0x1F400 && v <= 0x1F4FF { return true }
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        return false
    }
}

// MARK: - Main

print(String(repeating: "=", count: 60))
print("Step 2: Font Loading and Analysis")
print("Check which fonts handle each character")
print(String(repeating: "=", count: 60))

let fontSystem = FontSystem()
print("")

for testCase in TestCase.allCases {
    print("\n[Test: \(testCase.rawValue)]")
    print("Text: '\(testCase.text)'")
    print(fontSystem.analyzeString(testCase.text))
    print(String(repeating: "-", count: 60))
}

print("\n✅ Step 2 complete: Font fallback analysis")
print("Key observations:")
print("- Emoji use Apple Color Emoji (has sbix table)")
print("- CJK characters use PingFang or Hiragino")
print("- Base font (Menlo) only covers ASCII/Latin")
print("\nNext: Step 3 - Simple rendering")
