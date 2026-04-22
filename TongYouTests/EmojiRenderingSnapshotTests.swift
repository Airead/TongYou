import Testing
import Metal
import QuartzCore
import AppKit
@testable import TongYou

/// 生成emoji渲染的真实快照PNG
/// 运行: swift test --filter EmojiRenderingSnapshotTests
@Suite("Emoji Rendering Snapshots")
struct EmojiRenderingSnapshotTests {

    @Test func generateSnapshot() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device not available")
            return
        }

        let fontSystem = FontSystem(scaleFactor: 2.0)
        let renderer = MetalRenderer(device: device, fontSystem: fontSystem)

        // 构造测试场景：模拟用户的终端内容
        let screen = Screen(columns: 50, rows: 12)

        let testCases = [
            "TongYou git:(feat/support-emoji-again) 😀",
            "TongYou git:(feat/support-emoji-again) 👨‍👩‍👧‍👦",
            "TongYou git:(feat/support-emoji-again) 👋🏻",
            "TongYou git:(feat/support-emoji-again) 🇨🇳",
            "TongYou git:(feat/support-emoji-again) 🎉",
            "Hello 😀 World 🎉 Test",
            "中文🎊混合🇨🇳测试",
            "A👨‍👩‍👧‍👦B👋🏻C🇨🇳D🎉E",
        ]

        for (row, text) in testCases.enumerated() {
            screen.setCursorPos(row: row, col: 0)
            for char in text {
                screen.write(GraphemeCluster(char), attributes: .default)
            }
        }

        let snapshot = screen.snapshot()
        let screenSize = ScreenSize(width: 1200, height: 400)
        renderer.resize(screen: screenSize)
        renderer.setContent(snapshot)
        renderer.markDirty()

        // 创建渲染目标纹理
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(screenSize.width),
            height: Int(screenSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard device.makeTexture(descriptor: descriptor) != nil else {
            Issue.record("Failed to create texture")
            return
        }

        // 创建一个临时的 CAMetalLayer 来让 renderer 渲染
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.frame = CGRect(x: 0, y: 0, width: CGFloat(screenSize.width), height: CGFloat(screenSize.height))
        layer.drawableSize = CGSize(width: CGFloat(screenSize.width), height: CGFloat(screenSize.height))

        // 渲染一帧
        renderer.render(in: layer)

        // 等待渲染完成（让 renderer 内部完成 commandBuffer 提交）
        // 由于 render 是同步提交但没有 easy way 等待，我们给一点延迟
        Thread.sleep(forTimeInterval: 0.1)

        // 直接渲染到纹理的方式：手动调用 renderer 的渲染逻辑不可行，
        // 因为 render() 内部使用 layer.nextDrawable()。
        // 但 CAMetalLayer 在测试环境中可能拿不到 drawable。
        // 所以我们换一种方式：直接读取 atlas 纹理

        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // TongYouTests
            .deletingLastPathComponent() // Project root
            .path
        let outputDir = projectDir + "/emoji-render-output"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // 导出 emoji atlas 纹理
        try saveTextureAsPNG(
            texture: renderer.emojiAtlas.texture,
            path: outputDir + "/emoji-atlas.png"
        )

        // 导出 glyph atlas 纹理
        try saveTextureAsPNG(
            texture: renderer.glyphAtlas.texture,
            path: outputDir + "/glyph-atlas.png"
        )

        // 导出诊断信息
        let infoPath = outputDir + "/snapshot-info.txt"
        var info = ""
        info += "Emoji Snapshot\n"
        info += "===============\n\n"
        info += "Screen: \(screen.columns)x\(screen.rows)\n"
        info += "Size: \(screenSize.width)x\(screenSize.height)\n"
        info += "Font: \(fontSystem.pointSize)pt @ \(fontSystem.scaleFactor)x\n"
        info += "Cell: \(fontSystem.cellSize.width)x\(fontSystem.cellSize.height)\n\n"
        info += "Atlas entries:\n"
        info += "  Glyph: \(renderer.glyphAtlas.activeEntryCount)\n"
        info += "  Emoji: \(renderer.emojiAtlas.activeEntryCount)\n"
        info += "  Emoji texture: \(renderer.emojiAtlas.textureSize)x\(renderer.emojiAtlas.textureSize)\n"
        info += "  Glyph texture: \(renderer.glyphAtlas.textureSize)x\(renderer.glyphAtlas.textureSize)\n"
        try? info.write(toFile: infoPath, atomically: true, encoding: .utf8)

        print("✅ Atlas snapshots saved to: \(outputDir)")
    }

    private func saveTextureAsPNG(texture: MTLTexture, path: String) throws {
        let width = texture.width
        let height = texture.height

        let pixelData: [UInt8]
        let bytesPerRow: Int
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32

        switch texture.pixelFormat {
        case .r8Unorm:
            // Read 1 byte per pixel, then expand to BGRA grayscale
            let rawBytesPerRow = width
            var rawData = [UInt8](repeating: 0, count: rawBytesPerRow * height)
            texture.getBytes(
                &rawData,
                bytesPerRow: rawBytesPerRow,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0
            )
            // Expand R8 -> BGRA (grayscale with full alpha)
            var expandedData: [UInt8] = []
            expandedData.reserveCapacity(width * height * 4)
            for v in rawData {
                expandedData.append(v) // B
                expandedData.append(v) // G
                expandedData.append(v) // R
                expandedData.append(255) // A
            }
            pixelData = expandedData
            bytesPerRow = width * 4
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        case .bgra8Unorm:
            bytesPerRow = width * 4
            var rawData = [UInt8](repeating: 0, count: bytesPerRow * height)
            texture.getBytes(
                &rawData,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0
            )
            pixelData = rawData
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        default:
            throw NSError(domain: "Snapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported pixel format: \(texture.pixelFormat)"])
        }

        var mutablePixelData = pixelData
        let cgImage: CGImage? = mutablePixelData.withUnsafeMutableBytes { ptr -> CGImage? in
            let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
            return context?.makeImage()
        }

        guard let cgImage else {
            throw NSError(domain: "Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG"])
        }

        try pngData.write(to: URL(fileURLWithPath: path))
    }
}
