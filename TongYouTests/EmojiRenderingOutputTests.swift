import Testing
import Metal
import QuartzCore
import AppKit
@testable import TongYou

/// 生成emoji渲染对比图的测试
/// 运行: make test 并查看 build/Debug/emoji-render-output/ 目录
@Suite("Emoji Rendering Output")
struct EmojiRenderingOutputTests {

    /// 生成包含emoji的渲染图像
    @Test func generateEmojiComparisonImage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device not available")
            return
        }

        // 创建输出目录
        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let outputDir = projectDir + "/emoji-render-output"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // 创建字体系统
        let fontSystem = FontSystem(scaleFactor: 2.0)

        // 创建渲染器
        let renderer = MetalRenderer(device: device, fontSystem: fontSystem)

        // 创建测试屏幕内容
        let screen = Screen(columns: 40, rows: 10)

        // 写入测试内容
        let testCases = [
            ("😀 Simple emoji", 0),
            ("👨‍👩‍👧‍👦 ZWJ sequence", 1),
            ("👋🏻 Skin tone", 2),
            ("🇨🇳 Flag", 3),
            ("🎉🎊🎁 Multiple", 4),
            ("Hello 😀 World", 5),
            ("中文🎉Mixed", 6),
            ("A👨‍👩‍👧‍👦B👋🏻C🇨🇳D", 7),
        ]

        for (text, row) in testCases {
            screen.setCursorPos(row: row, col: 0)
            for char in text {
                let cluster = GraphemeCluster(char)
                screen.write(cluster, attributes: .default)
            }
        }

        // 获取快照
        let snapshot = screen.snapshot()

        // 设置渲染器
        renderer.resize(screen: ScreenSize(width: 800, height: 400))
        renderer.setContent(snapshot)

        // 创建输出纹理
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 800,
            height: 400,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        guard device.makeTexture(descriptor: textureDescriptor) != nil else {
            Issue.record("Failed to create output texture")
            return
        }

        // 创建Metal Layer
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.frame = CGRect(x: 0, y: 0, width: 800, height: 400)

        // 渲染
        renderer.markDirty()

        // 保存诊断信息
        let infoPath = outputDir + "/render-info.txt"
        var info = ""
        info += "Emoji Rendering Test\n"
        info += "==================\n\n"
        info += "Screen: 40x10\n"
        info += "Texture: 800x400\n"
        info += "Font: \(fontSystem.pointSize)pt @ \(fontSystem.scaleFactor)x\n"
        info += "Cell size: \(fontSystem.cellSize.width)x\(fontSystem.cellSize.height)\n\n"
        info += "Test cases:\n"
        for (text, row) in testCases {
            info += "  Row \(row): \(text)\n"
        }
        info += "\n"
        info += "Atlas Info:\n"
        info += "  GlyphAtlas entries: \(renderer.glyphAtlas.activeEntryCount)\n"
        info += "  ColorEmojiAtlas entries: \(renderer.emojiAtlas.activeEntryCount)\n"

        try? info.write(toFile: infoPath, atomically: true, encoding: .utf8)

        print("✅ Render info saved to: \(infoPath)")
    }

    /// 测试ColorEmojiAtlas直接输出
    @Test func testColorEmojiAtlasRasterization() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device not available")
            return
        }

        let projectDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let outputDir = projectDir + "/emoji-render-output"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let fontSystem = FontSystem(scaleFactor: 2.0)
        let atlas = ColorEmojiAtlas(device: device)

        // 测试不同的emoji
        let testEmojis = [
            "😀", "🎉", "👨‍👩‍👧‍👦", "👋🏻", "🇨🇳"
        ]

        var results: [String: EmojiGlyphInfo?] = [:]

        for emoji in testEmojis {
            let cluster = GraphemeCluster(Character(emoji))
            let info = atlas.getOrRasterize(cluster: cluster, fontSystem: fontSystem)
            results[emoji] = info
        }

        // 生成报告
        let reportPath = outputDir + "/atlas-report.txt"
        var report = "ColorEmojiAtlas Rasterization Report\n"
        report += "=================================\n\n"

        for (emoji, info) in results {
            if let glyphInfo = info {
                report += "\(emoji): OK\n"
                report += "  Size: \(glyphInfo.width)x\(glyphInfo.height)\n"
                report += "  Atlas: (\(glyphInfo.atlasX), \(glyphInfo.atlasY))\n"
                report += "  Bearings: (\(glyphInfo.bearingX), \(glyphInfo.bearingY))\n"
            } else {
                report += "\(emoji): FAILED (nil)\n"
            }
            report += "\n"
        }

        report += "Atlas stats:\n"
        report += "  Total entries: \(atlas.activeEntryCount)\n"
        report += "  Texture size: \(atlas.textureSize)x\(atlas.textureSize)\n"
        report += "  Is dirty: \(atlas.isDirty)\n"

        try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)

        print("✅ Atlas report saved to: \(reportPath)")

        // 验证所有emoji都被成功光栅化
        for (emoji, info) in results {
            #expect(info != nil, "Emoji \(emoji) should be rasterized")
            if let glyphInfo = info {
                #expect(glyphInfo.width > 0, "Emoji \(emoji) should have non-zero width")
                #expect(glyphInfo.height > 0, "Emoji \(emoji) should have non-zero height")
            }
        }
    }
}
