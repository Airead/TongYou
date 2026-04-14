#!/usr/bin/env swift
// emoji-render-test.swift
// 诊断脚本：生成emoji渲染对比图
// 使用方式: swift emoji-render-test.swift

import Foundation
import Metal
import CoreGraphics
import AppKit

// 需要链接的框架
// swift -framework Metal -framework CoreGraphics -framework AppKit emoji-render-test.swift

print("🔧 Emoji渲染诊断工具")
print("=====================")

// 1. 检查Metal可用性
guard let device = MTLCreateSystemDefaultDevice() else {
    print("❌ Metal设备不可用")
    exit(1)
}
print("✅ Metal设备: \(device.name)")

// 2. 创建渲染目标纹理
let textureWidth = 800
let textureHeight = 200

let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: textureWidth,
    height: textureHeight,
    mipmapped: false
)
textureDescriptor.usage = [.renderTarget, .shaderRead]
guard let targetTexture = device.makeTexture(descriptor: textureDescriptor) else {
    print("❌ 无法创建目标纹理")
    exit(1)
}

// 3. 创建命令队列
guard let commandQueue = device.makeCommandQueue() else {
    print("❌ 无法创建命令队列")
    exit(1)
}

// 4. 创建渲染管线
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    float4 vertices[] = {
        float4(-1.0, -1.0, 0.0, 1.0),  // 左下
        float4( 1.0, -1.0, 0.0, 1.0),  // 右下
        float4(-1.0,  1.0, 0.0, 1.0),  // 左上
        float4( 1.0,  1.0, 0.0, 1.0)   // 右上
    };
    float2 texCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = vertices[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]]) {
    // 测试色块：模拟emoji区域
    float x = in.texCoord.x;
    float y = in.texCoord.y;
    
    // 左半部分：模拟正常彩色emoji（蓝色渐变）
    if (x < 0.5) {
        return float4(0.2, 0.6, 1.0, 1.0);  // 蓝色（模拟正常）
    }
    // 右半部分：模拟当前问题（灰色方块）
    else {
        return float4(0.9, 0.9, 0.9, 1.0);  // 灰色（模拟问题）
    }
}
"""

// 编译shader
guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
    print("❌ Shader编译失败")
    exit(1)
}

guard let vertexFunc = library.makeFunction(name: "vertexShader"),
      let fragmentFunc = library.makeFunction(name: "fragmentShader") else {
    print("❌ 无法获取shader函数")
    exit(1)
}

// 创建渲染管线
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = vertexFunc
pipelineDescriptor.fragmentFunction = fragmentFunc
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
    print("❌ 无法创建渲染管线")
    exit(1)
}

// 5. 执行渲染
guard let commandBuffer = commandQueue.makeCommandBuffer(),
      let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
          let descriptor = MTLRenderPassDescriptor()
          descriptor.colorAttachments[0].texture = targetTexture
          descriptor.colorAttachments[0].loadAction = .clear
          descriptor.colorAttachments[0].storeAction = .store
          descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
          return descriptor
      }()) else {
    print("❌ 无法创建渲染命令")
    exit(1)
}

renderEncoder.setRenderPipelineState(pipelineState)
renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
renderEncoder.endEncoding()

commandBuffer.commit()
commandBuffer.waitUntilCompleted()

// 6. 读取纹理数据并保存为PNG
let bytesPerRow = textureWidth * 4
var pixelData = [UInt8](repeating: 0, count: bytesPerRow * textureHeight)

targetTexture.getBytes(
    &pixelData,
    bytesPerRow: bytesPerRow,
    from: MTLRegion(
        origin: MTLOrigin(x: 0, y: 0, z: 0),
        size: MTLSize(width: textureWidth, height: textureHeight, depth: 1)
    ),
    mipmapLevel: 0
)

// 创建CGImage
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

guard let context = CGContext(
    data: &pixelData,
    width: textureWidth,
    height: textureHeight,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo.rawValue
), let cgImage = context.makeImage() else {
    print("❌ 无法创建图像")
    exit(1)
}

// 7. 保存PNG
let outputPath = FileManager.default.currentDirectoryPath + "/emoji_render_test.png"
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: textureWidth, height: textureHeight))

if let tiffData = nsImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: outputPath))
    print("✅ 测试图已保存到: \(outputPath)")
}

print("\n📊 诊断信息:")
print("   - 左半边蓝色 = 正常彩色渲染")
print("   - 右半边灰色 = 当前问题状态")
print("\n💡 建议:")
print("   1. 运行 'make run' 启动TongYou")
print("   2. 输入: echo '😀🎉👨‍👩‍👧‍👦'")
print("   3. 对比实际渲染与测试图")
