#!/usr/bin/env swift

import AppKit
import CoreGraphics

// MARK: - Configuration

let iconSize: CGFloat = 1024
let outputDir = "TongYou/Assets.xcassets/AppIcon.appiconset"

// Cool black: near-black with a subtle cool/blue tint
let baseColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.06, 0.08, 0.12)
let lighten: CGFloat = 0.03
let darken: CGFloat = 0.03

func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

let gradientColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
    (clamp(baseColor.r + lighten), clamp(baseColor.g + lighten), clamp(baseColor.b + lighten)),
    (baseColor.r, baseColor.g, baseColor.b),
    (clamp(baseColor.r - darken), clamp(baseColor.g - darken), clamp(baseColor.b - darken)),
]

// MARK: - macOS Squircle Path

/// Generate a continuous-curvature rounded rectangle (squircle) matching macOS icon shape.
/// The corner radius is ~22.37% of the icon size per Apple's HIG.
func macOSSquirclePath(size: CGFloat) -> NSBezierPath {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2237
    return NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
}

// MARK: - CGPath from NSBezierPath

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}

// MARK: - Icon Rendering

func generateIcon() -> CGImage {
    let size = Int(iconSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext")
    }

    context.clear(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))

    // Clip to squircle
    let squircle = macOSSquirclePath(size: iconSize)
    context.addPath(squircle.cgPath)
    context.clip()

    // Draw gradient background
    let cgColors = gradientColors.map {
        CGColor(colorSpace: colorSpace, components: [$0.r, $0.g, $0.b, 1.0])!
    }

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: [0.0, 0.45, 1.0]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: iconSize / 2, y: iconSize),
            end: CGPoint(x: iconSize / 2, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Subtle top highlight
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.05])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.0])!,
    ]
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: [0.0, 0.35]) {
        context.saveGState()
        context.addPath(squircle.cgPath)
        context.clip()
        context.drawLinearGradient(
            glowGradient,
            start: CGPoint(x: iconSize / 2, y: iconSize),
            end: CGPoint(x: iconSize / 2, y: iconSize * 0.45),
            options: []
        )
        context.restoreGState()
    }

    // Draw SF Symbol "apple.terminal.on.rectangle" in white
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize * 0.52, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbolImage = NSImage(systemSymbolName: "apple.terminal.on.rectangle", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {

        let symbolSize = symbolImage.size
        let symbolRect = NSRect(
            x: (iconSize - symbolSize.width) / 2,
            y: (iconSize - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )

        // Drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -iconSize * 0.012)
        shadow.shadowBlurRadius = iconSize * 0.03
        shadow.set()

        symbolImage.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage() else {
        fatalError("Failed to create CGImage")
    }
    return cgImage
}

// MARK: - Export

func savePNG(_ sourceImage: CGImage, pixelSize: Int, to path: String) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize, height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("Failed to create resize context for size \(pixelSize)")
        return
    }

    context.interpolationQuality = .high
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

    guard let resized = context.makeImage() else {
        print("Failed to create resized image for size \(pixelSize)")
        return
    }

    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("Failed to create image destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, resized, nil)
    if CGImageDestinationFinalize(dest) {
        print("Generated: \(path) (\(pixelSize)x\(pixelSize))")
    } else {
        print("Failed to write \(path)")
    }
}

// macOS icon sizes: point sizes and their scale factors
let iconSpecs: [(pointSize: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// Generate
let icon = generateIcon()

// Build Contents.json
var images: [[String: String]] = []

for spec in iconSpecs {
    let pixelSize = spec.pointSize * spec.scale
    let filename = "icon_\(spec.pointSize)x\(spec.pointSize)@\(spec.scale)x.png"
    let path = "\(outputDir)/\(filename)"

    savePNG(icon, pixelSize: pixelSize, to: path)

    images.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(spec.scale)x",
        "size": "\(spec.pointSize)x\(spec.pointSize)",
    ])
}

// Write Contents.json
let contents: [String: Any] = [
    "images": images,
    "info": [
        "author": "xcode",
        "version": 1,
    ],
]

if let jsonData = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) {
    let jsonPath = "\(outputDir)/Contents.json"
    try? jsonData.write(to: URL(fileURLWithPath: jsonPath))
    print("Updated: \(jsonPath)")
}

print("Done! Icon generation complete.")
