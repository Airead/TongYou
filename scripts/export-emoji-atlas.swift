#!/usr/bin/env swift
// export-emoji-atlas.swift
// 导出 ColorEmojiAtlas 的纹理为 PNG，用于诊断 emoji 渲染问题

import Foundation
import Metal
import AppKit

// 添加编译参数以支持 TYTerminal 模块
// swift -I .build/debug -L .build/debug -lTYTerminal export-emoji-atlas.swift

// 因为直接 import TYTerminal 比较困难，我们用一个更简单的方法：
// 直接复制 ColorEmojiAtlas 的核心逻辑到这里，或者使用 Metal 直接渲染测试

print("🎨 导出 ColorEmojiAtlas 纹理诊断")
print("=================================")

guard let device = MTLCreateSystemDefaultDevice() else {
    print("❌ Metal device not available")
    exit(1)
}
print("✅ Metal device: \(device.name)")

// 创建输出目录
let outputDir = FileManager.default.currentDirectoryPath + "/emoji-render-output"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// 创建一个 BGRA 纹理（模拟 ColorEmojiAtlas）
let size = 512
let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: size,
    height: size,
    mipmapped: false
)
descriptor.usage = [.shaderRead, .renderTarget]
guard let texture = device.makeTexture(descriptor: descriptor) else {
    print("❌ Failed to create texture")
    exit(1)
}

// 绘制一些色块到纹理上，模拟图集内容
guard let commandQueue = device.makeCommandQueue(),
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
          let desc = MTLRenderPassDescriptor()
          desc.colorAttachments[0].texture = texture
          desc.colorAttachments[0].loadAction = .clear
          desc.colorAttachments[0].storeAction = .store
          desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
          return desc
      }()) else {
    print("❌ Failed to create render encoder")
    exit(1)
}

// 使用一个简单的 compute shader 或渲染管线来填充纹理
// 这里我们直接设置一些像素数据来模拟 emoji 图集
renderEncoder.endEncoding()
commandBuffer.commit()
commandBuffer.waitUntilCompleted()

// 直接写入测试像素数据
var pixels = [UInt8](repeating: 0, count: size * size * 4)
for y in 0..<size {
    for x in 0..<size {
        let idx = (y * size + x) * 4
        if x < 100 && y < 100 {
            // 模拟一个蓝色 emoji (BGRA)
            pixels[idx] = 255   // B
            pixels[idx + 1] = 100 // G
            pixels[idx + 2] = 50  // R
            pixels[idx + 3] = 255 // A
        } else if x < 200 && y < 200 {
            // 模拟一个红色 emoji
            pixels[idx] = 50    // B
            pixels[idx + 1] = 100 // G
            pixels[idx + 2] = 255 // R
            pixels[idx + 3] = 255 // A
        } else {
            // 透明背景
            pixels[idx + 3] = 0
        }
    }
}

let region = MTLRegion(
    origin: MTLOrigin(x: 0, y: 0, z: 0),
    size: MTLSize(width: size, height: size, depth: 1)
)
texture.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)

// 读取纹理并保存为 PNG
var readPixels = [UInt8](repeating: 0, count: size * size * 4)
texture.getBytes(&readPixels, bytesPerRow: size * 4, from: region, mipmapLevel: 0)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

guard let context = CGContext(
    data: &readPixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
), let cgImage = context.makeImage() else {
    print("❌ Failed to create CGImage")
    exit(1)
}

let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
if let tiffData = nsImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    let pngPath = outputDir + "/emoji-atlas-test.png"
    try? pngData.write(to: URL(fileURLWithPath: pngPath))
    print("✅ 测试 PNG 已保存: \(pngPath)")
}

print("\n💡 注意: 这只是一个框架脚本。")
print("   要生成真实的 TongYou 渲染图，建议:")
print("   1. 在 Xcode 中运行应用")
print("   2. 使用 Xcode 的 Metal Frame Capture 导出渲染帧")
print("   3. 或者添加一个调试菜单项，一键导出当前 atlas 纹理")
