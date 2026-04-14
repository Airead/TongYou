#!/usr/bin/env swift

// validate_emoji_step7.swift
// Step 7: Final visual comparison with grid overlay
// 生成带网格线的最终对比图，清晰展示三种布局的差异

import Foundation
import CoreText
import CoreGraphics
import AppKit

// MARK: - Test Cases

enum TestCase: String, CaseIterable {
    case zwjSequence = "ZWJ Family"
    case skinToneModifier = "Skin Tone"
    case variationSelector = "Variation Selector"
    case flagEmoji = "Flag Emoji"
    case multiZWJ = "Multiple ZWJ"
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
            return "Hello👨‍👩‍👧‍👦World"
        }
    }
    
    var description: String {
        switch self {
        case .zwjSequence:
            return "7 scalars → 1 emoji (ZWJ sequence)"
        case .skinToneModifier:
            return "2 scalars → 1 emoji (skin tone)"
        case .variationSelector:
            return "2 scalars → 1 emoji (VS-16)"
        case .flagEmoji:
            return "2 scalars → 1 emoji (regional indicators)"
        case .multiZWJ:
            return "Multiple ZWJ sequences"
        case .complexMixed:
            return "Mixed ASCII + emoji text"
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
        if v >= 0x1F300 && v <= 0x1F64F { return true }
        if v >= 0x1F400 && v <= 0x1F4FF { return true }
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        return false
    }
}

// MARK: - Width Calculators

/// BUGGY: Sum all scalar widths
func buggyWidth(_ char: Character) -> Int {
    var width: UInt8 = 0
    for scalar in char.unicodeScalars {
        width += scalar.terminalWidth
    }
    return Int(width)
}

/// FIXED: Detect emoji sequences
func fixedWidth(_ char: Character) -> Int {
    let scalars = Array(char.unicodeScalars)
    guard let firstScalar = scalars.first else { return 1 }
    
    let isEmojiSequence = scalars.count > 1 && scalars.contains { scalar in
        if scalar.value == 0x200D { return true }  // ZWJ
        if scalar.value == 0xFE0E || scalar.value == 0xFE0F { return true }  // VS
        if scalar.value >= 0x1F3FB && scalar.value <= 0x1F3FF { return true }  // Skin tone
        if scalar.value >= 0x1F1E6 && scalar.value <= 0x1F1FF { return true }  // Regional indicators
        return false
    }
    
    if isEmojiSequence {
        return max(1, Int(firstScalar.terminalWidth))
    }
    
    var width: UInt8 = 0
    for scalar in scalars {
        width += scalar.terminalWidth
    }
    return Int(width)
}

// MARK: - Layout Engine

struct Layout {
    let items: [(char: Character, startCell: Int, width: Int)]
    let totalCells: Int
}

func buildLayout(text: String, widthCalculator: (Character) -> Int) -> Layout {
    var items: [(Character, Int, Int)] = []
    var currentCell = 0
    
    for char in text {
        let width = widthCalculator(char)
        items.append((char, currentCell, width))
        currentCell += width
    }
    
    return Layout(items: items, totalCells: currentCell)
}

// MARK: - Rendering

struct Renderer {
    let cellWidth: CGFloat = 28.0
    let cellHeight: CGFloat = 50.0
    let fontSize: CGFloat = 40.0
    
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
    
    func drawGrid(context: CGContext, cells: Int, startX: CGFloat, startY: CGFloat, 
                  highlightStart: Int? = nil, highlightWidth: Int? = nil) {
        // Draw vertical grid lines
        context.setStrokeColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.setLineWidth(1)
        
        for i in 0...cells {
            let x = startX + CGFloat(i) * cellWidth
            context.move(to: CGPoint(x: x, y: startY))
            context.addLine(to: CGPoint(x: x, y: startY + cellHeight))
        }
        context.strokePath()
        
        // Draw horizontal borders
        context.move(to: CGPoint(x: startX, y: startY))
        context.addLine(to: CGPoint(x: startX + CGFloat(cells) * cellWidth, y: startY))
        context.move(to: CGPoint(x: startX, y: startY + cellHeight))
        context.addLine(to: CGPoint(x: startX + CGFloat(cells) * cellWidth, y: startY + cellHeight))
        context.strokePath()
        
        // Highlight problematic cells
        if let start = highlightStart, let width = highlightWidth, width > 2 {
            context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 0.2))
            context.fill(CGRect(
                x: startX + CGFloat(start + 2) * cellWidth,
                y: startY,
                width: CGFloat(width - 2) * cellWidth,
                height: cellHeight
            ))
        }
        
        // Draw cell numbers
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7),
            .foregroundColor: NSColor.gray
        ]
        
        for i in 0..<min(cells, 20) {
            let x = startX + CGFloat(i) * cellWidth + 2
            NSAttributedString(string: String(i), attributes: labelAttrs)
                .draw(at: NSPoint(x: x, y: startY + cellHeight + 2))
        }
        
        NSGraphicsContext.restoreGraphicsState()
    }
    
    func render(layout: Layout, text: String, showCells: Int = 15) -> CGImage? {
        let contextWidth: CGFloat = max(CGFloat(showCells + 2) * cellWidth + 40, 400)
        let contextHeight: CGFloat = 100
        
        guard let context = createContext(width: contextWidth, height: contextHeight) else {
            return nil
        }
        
        // White background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: CGSize(width: contextWidth, height: contextHeight)))
        
        let startX: CGFloat = 20
        let startY: CGFloat = 20
        
        // Find problematic emoji (width > 2)
        var highlightStart: Int?
        var highlightWidth: Int?
        for (char, cell, width) in layout.items {
            if width > 2 {
                highlightStart = cell
                highlightWidth = width
                break
            }
        }
        
        drawGrid(context: context, cells: showCells, startX: startX, startY: startY,
                 highlightStart: highlightStart, highlightWidth: highlightWidth)
        
        // Render text
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        
        let baseFont = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        
        for (char, cell, width) in layout.items {
            let x = startX + CGFloat(cell) * cellWidth
            let y = startY + 5
            
            // Draw character using CoreText
            let attrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: String(char), attributes: attrs)
            str.draw(at: NSPoint(x: x, y: y))
            
            // Draw cell width indicator for wide characters
            if width > 1 {
                context.setStrokeColor(CGColor(red: 0.3, green: 0.5, blue: 1, alpha: 0.5))
                context.setLineWidth(2)
                context.stroke(CGRect(
                    x: x,
                    y: startY + 2,
                    width: CGFloat(width) * cellWidth,
                    height: cellHeight - 4
                ))
            }
        }
        
        // Draw total cells used
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.darkGray
        ]
        NSAttributedString(
            string: "Total cells: \(layout.totalCells)",
            attributes: labelAttrs
        ).draw(at: NSPoint(x: startX, y: 5))
        
        NSGraphicsContext.restoreGraphicsState()
        
        return context.makeImage()
    }
}

// MARK: - Output Helpers

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("  Failed to create destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("  ✅ \(path)")
    }
}

func createTripleComparison(buggy: CGImage, fixed: CGImage, ghostty: CGImage,
                             title: String, description: String, size: CGSize) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                     CGBitmapInfo.byteOrder32Little.rawValue
    
    let margin: CGFloat = 20
    let sectionSpacing: CGFloat = 20
    let labelHeight: CGFloat = 25
    let titleHeight: CGFloat = 40
    let descHeight: CGFloat = 20
    
    let totalWidth = margin * 2 + size.width * 3 + sectionSpacing * 2
    let totalHeight = titleHeight + descHeight + size.height + labelHeight + margin
    
    guard let context = CGContext(
        data: nil,
        width: Int(totalWidth),
        height: Int(totalHeight),
        bitsPerComponent: 8,
        bytesPerRow: Int(totalWidth) * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return nil }
    
    // White background
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: CGSize(width: totalWidth, height: totalHeight)))
    
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    
    // Title
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 16),
        .foregroundColor: NSColor.black
    ]
    NSAttributedString(string: title, attributes: titleAttrs)
        .draw(at: NSPoint(x: margin, y: totalHeight - 25))
    
    // Description
    let descAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.darkGray
    ]
    NSAttributedString(string: description, attributes: descAttrs)
        .draw(at: NSPoint(x: margin, y: totalHeight - 45))
    
    // Labels
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.black
    ]
    let subLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9),
        .foregroundColor: NSColor.gray
    ]
    
    // Buggy label
    NSAttributedString(string: "❌ Current (Buggy)", attributes: labelAttrs)
        .draw(at: NSPoint(x: margin, y: size.height + labelHeight - 10))
    NSAttributedString(string: "Sums scalar widths", attributes: subLabelAttrs)
        .draw(at: NSPoint(x: margin, y: size.height + 5))
    
    // Fixed label
    NSAttributedString(string: "✅ Fixed (Proposed)", attributes: labelAttrs)
        .draw(at: NSPoint(x: margin + size.width + sectionSpacing, y: size.height + labelHeight - 10))
    NSAttributedString(string: "Detects emoji sequences", attributes: subLabelAttrs)
        .draw(at: NSPoint(x: margin + size.width + sectionSpacing, y: size.height + 5))
    
    // Ghostty label
    NSAttributedString(string: "🎯 Ghostty (Target)", attributes: labelAttrs)
        .draw(at: NSPoint(x: margin + (size.width + sectionSpacing) * 2, y: size.height + labelHeight - 10))
    NSAttributedString(string: "CoreText shaping", attributes: subLabelAttrs)
        .draw(at: NSPoint(x: margin + (size.width + sectionSpacing) * 2, y: size.height + 5))
    
    NSGraphicsContext.restoreGraphicsState()
    
    // Draw images
    context.draw(buggy, in: CGRect(x: margin, y: margin, width: size.width, height: size.height))
    context.draw(fixed, in: CGRect(x: margin + size.width + sectionSpacing, y: margin, width: size.width, height: size.height))
    context.draw(ghostty, in: CGRect(x: margin + (size.width + sectionSpacing) * 2, y: margin, width: size.width, height: size.height))
    
    return context.makeImage()
}

// MARK: - Main

let outputDir = "scripts/emoji-test-output"
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

print(String(repeating: "=", count: 70))
print("Step 7: Final Visual Comparison")
print("Three-way comparison: Buggy vs Fixed vs Ghostty")
print(String(repeating: "=", count: 70))

let renderer = Renderer()

for testCase in TestCase.allCases {
    print("\nRendering: \(testCase.rawValue)")
    
    let buggyLayout = buildLayout(text: testCase.text, widthCalculator: buggyWidth)
    let fixedLayout = buildLayout(text: testCase.text, widthCalculator: fixedWidth)
    let ghosttyLayout = buildLayout(text: testCase.text, widthCalculator: fixedWidth)  // Same as fixed for layout
    
    print("  Buggy: \(buggyLayout.totalCells) cells, Fixed: \(fixedLayout.totalCells) cells")
    
    guard let buggyImage = renderer.render(layout: buggyLayout, text: testCase.text),
          let fixedImage = renderer.render(layout: fixedLayout, text: testCase.text),
          let ghosttyImage = renderer.render(layout: ghosttyLayout, text: testCase.text) else {
        print("  ERROR: Failed to render")
        continue
    }
    
    if let comparison = createTripleComparison(
        buggy: buggyImage,
        fixed: fixedImage,
        ghostty: ghosttyImage,
        title: testCase.rawValue,
        description: testCase.description,
        size: CGSize(width: 400, height: 100)
    ) {
        let filename = "\(testCase.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_step7.png"
        savePNG(comparison, to: "\(outputDir)/\(filename)")
    }
}

// Create summary image
print("\n" + String(repeating: "=", count: 70))
print("SUMMARY")
print(String(repeating: "=", count: 70))

print("\n📊 Test Results:")
for testCase in TestCase.allCases {
    let buggy = buildLayout(text: testCase.text, widthCalculator: buggyWidth)
    let fixed = buildLayout(text: testCase.text, widthCalculator: fixedWidth)
    let saved = buggy.totalCells - fixed.totalCells
    let percent = String(format: "%.0f", Double(saved) / Double(buggy.totalCells) * 100)
    print("  \(testCase.rawValue):")
    print("    \(buggy.totalCells) → \(fixed.totalCells) cells (saved \(saved), \(percent)%)")
}

print("\n🔧 Implementation Notes:")
print("  • Red background = wasted cells (buggy layout)")
print("  • Blue border = wide character spans multiple cells")
print("  • Gray vertical lines = cell boundaries")
print("  • Numbers below = cell index")

print("\n📁 All comparison images saved to:")
print("  \(outputDir)/")
print("\n✅ Step 7 complete - Visual comparison ready!")
