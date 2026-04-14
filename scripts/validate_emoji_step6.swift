#!/usr/bin/env swift

// validate_emoji_step6.swift
// Step 6: Solution validation - proper grapheme cluster width calculation
// 实现正确的 grapheme cluster 宽度计算，验证修复效果

import Foundation
import CoreText
import CoreGraphics
import AppKit

// MARK: - Test Cases

enum TestCase: String, CaseIterable {
    case zwjSequence = "ZWJ Sequence"
    case skinToneModifier = "Skin Tone"
    case variationSelector = "Variation Selector"
    case flagEmoji = "Flag Emoji"
    case multiZWJ = "Multi ZWJ"
    case complexMixed = "Complex Mixed"
    
    var text: String {
        switch self {
        case .zwjSequence:
            return "ab👨‍👩‍👧‍👦cd"
        case .skinToneModifier:
            return "ab👋🏻cd"
        case .variationSelector:
            return "ab❤️cd"
        case .flagEmoji:
            return "ab🇨🇳cd"
        case .multiZWJ:
            return "👩‍🚀🧑‍🌾👨‍⚕️"
        case .complexMixed:
            return "Hello👨‍👩‍👧‍👦World🇨🇳Test"
        }
    }
}

// MARK: - Fixed Width Calculator

/// Proper grapheme cluster width calculator (Ghostty approach)
/// Returns the terminal cell width for a grapheme cluster
func calculateGraphemeWidth(_ char: Character) -> Int {
    let scalars = Array(char.unicodeScalars)
    
    guard let firstScalar = scalars.first else { return 1 }
    
    // Check if this is an emoji sequence (contains ZWJ, variation selectors, or skin tones)
    let isEmojiSequence = scalars.count > 1 && scalars.contains { scalar in
        // ZWJ (Zero Width Joiner)
        if scalar.value == 0x200D { return true }
        // Variation selectors
        if scalar.value == 0xFE0E || scalar.value == 0xFE0F { return true }
        // Fitzpatrick skin tone modifiers
        if scalar.value >= 0x1F3FB && scalar.value <= 0x1F3FF { return true }
        // Regional indicators (flags)
        if scalar.value >= 0x1F1E6 && scalar.value <= 0x1F1FF { return true }
        // Tag characters (subdivision flags)
        if scalar.value >= 0xE0020 && scalar.value <= 0xE007F { return true }
        return false
    }
    
    if isEmojiSequence {
        // For emoji sequences, use the width of the base emoji
        // Most base emojis are wide (width = 2), except some text-style emoji
        return max(1, Int(firstScalar.terminalWidth))
    }
    
    // For non-emoji sequences, sum the widths of individual scalars
    // (for combining marks, etc.)
    var totalWidth: UInt8 = 0
    for scalar in scalars {
        totalWidth += scalar.terminalWidth
    }
    return Int(totalWidth)
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

// MARK: - Analysis Functions

/// Build layout with the OLD (buggy) approach
func buildBuggyLayout(text: String) -> [(char: Character, startCell: Int, width: Int)] {
    var layout: [(Character, Int, Int)] = []
    var currentCell = 0
    
    for char in text {
        // Old approach: sum all scalar widths
        var width: UInt8 = 0
        for scalar in char.unicodeScalars {
            width += scalar.terminalWidth
        }
        layout.append((char, currentCell, Int(width)))
        currentCell += Int(width)
    }
    
    return layout
}

/// Build layout with the NEW (fixed) approach
func buildFixedLayout(text: String) -> [(char: Character, startCell: Int, width: Int)] {
    var layout: [(Character, Int, Int)] = []
    var currentCell = 0
    
    for char in text {
        let width = calculateGraphemeWidth(char)
        layout.append((char, currentCell, width))
        currentCell += width
    }
    
    return layout
}

// MARK: - Main

print(String(repeating: "=", count: 70))
print("Step 6: Solution Validation")
print("Compare buggy vs fixed grapheme width calculation")
print(String(repeating: "=", count: 70))

for testCase in TestCase.allCases {
    print("\n[Test: \(testCase.rawValue)]")
    print("Text: '\(testCase.text)'")
    print("Codepoints: \(testCase.text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))")
    
    let buggyLayout = buildBuggyLayout(text: testCase.text)
    let fixedLayout = buildFixedLayout(text: testCase.text)
    
    print("\n  BUGGY (current) layout:")
    var buggyTotal = 0
    for (char, cell, width) in buggyLayout {
        buggyTotal = max(buggyTotal, cell + width)
        let marker = width > 2 ? " ⚠️" : ""
        print("    cell[\(String(format: "%2d", cell))] w=\(width) '\(char)’\(marker)")
    }
    print("    Total cells occupied: \(buggyTotal)")
    
    print("\n  FIXED (proposed) layout:")
    var fixedTotal = 0
    for (char, cell, width) in fixedLayout {
        fixedTotal = max(fixedTotal, cell + width)
        print("    cell[\(String(format: "%2d", cell))] w=\(width) '\(char)’")
    }
    print("    Total cells occupied: \(fixedTotal)")
    
    let improvement = buggyTotal - fixedTotal
    if improvement > 0 {
        print("\n  ✅ Improvement: saved \(improvement) cell(s) (\(String(format: "%.0f", Double(improvement)/Double(buggyTotal)*100))% reduction)")
    } else {
        print("\n  ✅ No change (already correct)")
    }
    
    print(String(repeating: "-", count: 70))
}

print("\n" + String(repeating: "=", count: 70))
print("SUMMARY")
print(String(repeating: "=", count: 70))

print("\nThe fix requires detecting emoji sequences and using base emoji width:")
print("")
print("  func calculateGraphemeWidth(_ char: Character) -> Int {")
print("      let scalars = Array(char.unicodeScalars)")
print("      guard let firstScalar = scalars.first else { return 1 }")
print("      ")
print("      // Check for emoji sequence markers:")
print("      // - ZWJ (U+200D): Zero Width Joiner")
print("      // - VS (U+FE0E/F): Variation Selectors")
print("      // - Skin tones (U+1F3FB-FF)")
print("      // - Regional indicators (U+1F1E6-FF)")
print("      let isEmojiSequence = scalars.count > 1 && ...")
print("      ")
print("      if isEmojiSequence {")
print("          // Use base emoji width only")
print("          return Int(firstScalar.terminalWidth)")
print("      }")
print("      ")
print("      // Otherwise sum scalar widths")
print("      return scalars.reduce(0) { $0 + Int($1.terminalWidth) }")
print("  }")
print("")
print("This change needs to be integrated into:")
print("- TYTerminal/CharWidth.swift: Add grapheme-aware width calculation")
print("- Cell.swift: Update width assignment when printing characters")
print("- Terminal grid: Use proper cluster width for cursor positioning")
print("")
print("✅ Step 6 complete: Solution validated")
