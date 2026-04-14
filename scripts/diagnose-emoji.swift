#!/usr/bin/env swift
// diagnose-emoji.swift
// 诊断TongYou的emoji渲染问题
// 运行: swift diagnose-emoji.swift

import Foundation

// MARK: - 配置
let outputDir = FileManager.default.currentDirectoryPath + "/emoji-diagnose"
let testStrings = [
    "😀 简单笑脸",
    "👨‍👩‍👧‍👦 ZWJ序列",
    "👋🏻 肤色修饰",
    "🇨🇳 国旗",
    "🎉🎊🎁 多个emoji",
    "Hello 😀 World 🎉",
    "中文🎉混合",
    "A👨‍👩‍👧‍👦B👋🏻C🇨🇳D"
]

// MARK: - 主程序
print("🔍 TongYou Emoji渲染诊断")
print("==========================")

// 创建输出目录
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// 1. 检查TongYou是否已构建
let buildDir = FileManager.default.currentDirectoryPath + "/.build/debug"
let tongyouCLI = buildDir + "/tongyou"

if !FileManager.default.fileExists(atPath: tongyouCLI) {
    print("⚠️ TongYou CLI未找到，尝试构建...")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
    process.arguments = ["build"]
    process.currentDirectoryPath = FileManager.default.currentDirectoryPath
    
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            print("❌ 构建失败")
            exit(1)
        }
    } catch {
        print("❌ 无法执行构建: \(error)")
        exit(1)
    }
}

print("✅ TongYou已准备好")

// 2. 生成测试HTML报告
var htmlContent = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>TongYou Emoji渲染诊断</title>
    <style>
        body { font-family: -apple-system, sans-serif; padding: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { color: #333; }
        .test-case { 
            background: white; 
            padding: 20px; 
            margin: 20px 0; 
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .label { font-weight: bold; color: #666; margin-bottom: 10px; }
        .content { 
            padding: 15px; 
            background: #1e1e1e; 
            color: #fff;
            font-family: 'Menlo', monospace;
            font-size: 16px;
            border-radius: 4px;
            margin: 10px 0;
        }
        .emoji { 
            font-size: 24px; 
            margin: 0 2px;
        }
        .grid { 
            display: grid; 
            grid-template-columns: 1fr 1fr; 
            gap: 20px;
            margin-top: 20px;
        }
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: bold;
        }
        .status-ok { background: #4caf50; color: white; }
        .status-warn { background: #ff9800; color: white; }
        .status-error { background: #f44336; color: white; }
        .info {
            background: #e3f2fd;
            padding: 15px;
            border-radius: 4px;
            margin: 20px 0;
        }
        code {
            background: #f5f5f5;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Menlo', monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 TongYou Emoji渲染诊断报告</h1>
        <div class="info">
            <strong>测试时间:</strong> \(Date())<br>
            <strong>测试目的:</strong> 验证双图集系统是否正确渲染彩色emoji<br>
            <strong>期望结果:</strong> 所有emoji应显示为彩色，而非灰色方块
        </div>
        
        <h2>📋 测试用例</h2>
"""

// 3. 为每个测试字符串生成测试用例
for (index, testStr) in testStrings.enumerated() {
    // 分析emoji
    let emojis = extractEmojis(from: testStr)
    let hasZWJ = emojis.contains { $0.contains("\u{200D}") }
    let hasSkinTone = emojis.contains { 
        $0.unicodeScalars.contains { scalar in
            scalar.value >= 0x1F3FB && scalar.value <= 0x1F3FF
        }
    }
    let hasFlag = emojis.contains {
        $0.unicodeScalars.contains { scalar in
            scalar.value >= 0x1F1E6 && scalar.value <= 0x1F1FF
        }
    }
    
    let issues = [hasZWJ ? "ZWJ序列" : nil, hasSkinTone ? "肤色修饰" : nil, hasFlag ? "国旗" : nil]
        .compactMap { $0 }
    
    htmlContent += """
        <div class="test-case">
            <div class="label">
                测试 #\(index + 1)
                \(issues.isEmpty ? "" : "<span class='status status-warn'>包含: \(issues.joined(separator: ", "))</span>")
            </div>
            <div class="content">\(escapeHTML(testStr))</div>
            <div style="font-size: 20px; margin: 10px 0;">
                浏览器渲染: \(testStr)
            </div>
            <div class="grid">
                <div>
                    <strong>期望效果（参考）:</strong><br>
                    <div style="padding: 10px; background: #f5f5f5; border-radius: 4px; margin-top: 5px;">
                        彩色emoji，每个emoji占据1-2个单元格宽度<br>
                        ZWJ序列应显示为单个合并图像<br>
                        肤色修饰应与基础emoji组合显示
                    </div>
                </div>
                <div>
                    <strong>常见问题:</strong><br>
                    <div style="padding: 10px; background: #fff3e0; border-radius: 4px; margin-top: 5px;">
                        ❌ 灰色方块（emoji未被识别）<br>
                        ❌ 多个方块（ZWJ序列被拆分）<br>
                        ❌ 黑白显示（使用了文字图集而非彩色图集）
                    </div>
                </div>
            </div>
        </div>
"""
}

// 4. 添加调试信息
htmlContent += """
        <h2>🔧 调试信息</h2>
        <div class="test-case">
            <h3>阶段3实现状态</h3>
            <ul>
                <li>ColorEmojiAtlas: <span class="status status-ok">已实现</span></li>
                <li>BGRA纹理: <span class="status status-ok">已实现</span></li>
                <li>MetalRenderer双图集: <span class="status status-ok">已实现</span></li>
                <li>cell_emoji_fragment着色器: <span class="status status-ok">已实现</span></li>
            </ul>
            
            <h3>可能的问题原因</h3>
            <ol>
                <li><strong>emoji识别失败:</strong> ColorEmojiAtlas的isEmojiScalar判断不正确</li>
                <li><strong>光栅化失败:</strong> Apple Color Emoji字体无法渲染（可能需要检查字体可用性）</li>
                <li><strong>渲染顺序错误:</strong> emoji被文字覆盖（应该后绘制emoji）</li>
                <li><strong>纹理坐标错误:</strong> emoji图集数据未正确上传到GPU</li>
                <li><strong>缓存未命中:</strong> getOrRasterize返回了nil</li>
            </ol>
            
            <h3>排查步骤</h3>
            <ol>
                <li>在 <code>fillTextInstanceBuffer</code> 中添加断点，检查 <code>emojiAtlas.getOrRasterize</code> 返回值</li>
                <li>检查 <code>ColorEmojiAtlas.rasterizeEmoji</code> 是否成功生成bitmap</li>
                <li>验证 <code>isEmojiSequence</code> 是否正确识别emoji</li>
                <li>查看 <code>emojiInstanceCount</code> 是否大于0</li>
                <li>使用Xcode的Metal Frame Capture查看实际渲染的纹理</li>
            </ol>
        </div>
        
        <h2>🧪 快速测试</h2>
        <div class="test-case">
            <p>在TongYou终端中运行以下命令进行测试：</p>
            <pre style="background: #1e1e1e; color: #4caf50; padding: 15px; border-radius: 4px; overflow-x: auto;">
printf '😀\\n'
printf '👨‍👩‍👧‍👦\\n'  
printf '👋🏻\\n'
printf '🇨🇳\\n'
printf '🎉🎊🎁\\n'
echo -e '😀\\xF0\\x9F\\x98\\x80'
            </pre>
            <p>或者使用Python生成emoji：</p>
            <pre style="background: #1e1e1e; color: #4caf50; padding: 15px; border-radius: 4px; overflow-x: auto;">
python3 -c "print('😀👨‍👩‍👧‍👦👋🏻🇨🇳🎉')"
            </pre>
        </div>
    </div>
</body>
</html>
"""

// 5. 保存HTML报告
let reportPath = outputDir + "/report.html"
try? htmlContent.write(toFile: reportPath, atomically: true, encoding: .utf8)

print("\n✅ 诊断报告已生成: \(reportPath)")
print("\n📊 下一步操作:")
print("   1. 在浏览器中打开 \(reportPath)")
print("   2. 运行 'make run' 启动TongYou")
print("   3. 在TongYou中输入: printf '😀\\n'")
print("   4. 对比浏览器和TongYou的显示效果")
print("\n🔍 查看调试日志:")
print("   1. 在Xcode中打开TongYou.xcodeproj")
print("   2. 在 MetalRenderer.swift:fillTextInstanceBuffer 设置断点")
print("   3. 检查 emojiInstanceCount 是否大于0")

// MARK: - 辅助函数

func extractEmojis(from string: String) -> [String] {
    var emojis: [String] = []
    var index = string.startIndex
    
    while index < string.endIndex {
        let character = string[index]
        if character.unicodeScalars.count > 1 || 
           (character.unicodeScalars.first?.value ?? 0) >= 0x1F600 {
            emojis.append(String(character))
        }
        index = string.index(after: index)
    }
    
    return emojis
}

func escapeHTML(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// 生成PTY测试脚本
let ptyTestScript = """
#!/bin/bash
# pty-emoji-test.sh
# 在TongYou中运行此脚本测试emoji渲染

echo "=== TongYou Emoji 渲染测试 ==="
echo ""
echo "1. 简单emoji:"
printf '😀😎🎉🚀\\n'
echo ""
echo "2. ZWJ序列 (家庭):"
printf '👨‍👩‍👧‍👦\\n'
echo ""
echo "3. 肤色修饰:"
printf '👋🏻👋🏿\\n'
echo ""
echo "4. 国旗:"
printf '🇨🇳🇺🇸🇯🇵\\n'
echo ""
echo "5. 混合文本:"
printf 'Hello 😀 World 🎉\\n'
printf '中文测试🎊英文测试\\n'
echo ""
echo "=== 测试完成 ==="
"""

let scriptPath = outputDir + "/pty-emoji-test.sh"
try? ptyTestScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

print("\n📝 PTY测试脚本: \(scriptPath)")
print("   在TongYou中运行: bash \(scriptPath)")
