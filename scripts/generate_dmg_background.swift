#!/usr/bin/env swift

/// Generate DMG installer background image.
///
/// Creates a 600x400 background with a dark cool gradient
/// that complements TongYou's dark icon style.

import AppKit
import CoreGraphics

let width = 600
let height = 400
let outputPath = "resources/dmg-background.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: width, height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

// Light cool gray gradient — neutral so the dark icon pops, black labels stay readable
let topColor = CGColor(colorSpace: colorSpace, components: [0.92, 0.91, 0.94, 1.0])!
let bottomColor = CGColor(colorSpace: colorSpace, components: [0.82, 0.80, 0.86, 1.0])!

if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: width / 2, y: height),
        end: CGPoint(x: width / 2, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

guard let image = context.makeImage() else {
    fatalError("Failed to create CGImage")
}

let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Failed to create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("Failed to write PNG")
}

let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
print("Saved \(outputPath) (\(width)x\(height), \(fileSize / 1024) KB)")
