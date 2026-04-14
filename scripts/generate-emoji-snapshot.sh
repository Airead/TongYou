#!/bin/bash
# generate-emoji-snapshot.sh
# 生成 TongYou emoji 渲染的真实快照

set -e

echo "📸 TongYou Emoji 渲染快照生成器"
echo "================================"

OUTPUT_DIR="$(pwd)/emoji-render-output"
mkdir -p "$OUTPUT_DIR"

echo ""
echo "🏗️  步骤 1: 构建项目..."
make build > /dev/null 2>&1
echo "✅ 构建完成"

echo ""
echo "📷 步骤 2: 运行渲染快照测试..."
# 运行特定的测试来生成 atlas 图片
xcodebuild test \
    -scheme TongYou \
    -destination 'platform=macOS' \
    -only-testing:TongYouTests/EmojiRenderingSnapshotTests \
    2>&1 | grep -E "(✅|❌|Test|passed|failed)" || true

echo ""

# 检查输出文件
if [ -f "$OUTPUT_DIR/emoji-atlas.png" ]; then
    echo "✅ Emoji Atlas 已生成: $OUTPUT_DIR/emoji-atlas.png"
else
    echo "⚠️  Emoji Atlas 未找到"
fi

if [ -f "$OUTPUT_DIR/glyph-atlas.png" ]; then
    echo "✅ Glyph Atlas 已生成: $OUTPUT_DIR/glyph-atlas.png"
else
    echo "⚠️  Glyph Atlas 未找到"
fi

if [ -f "$OUTPUT_DIR/snapshot-info.txt" ]; then
    echo ""
    echo "📊 诊断信息:"
    echo "-------------"
    cat "$OUTPUT_DIR/snapshot-info.txt"
fi

echo ""
echo "🖼️  查看结果:"
echo "-------------"
if [ -f "$OUTPUT_DIR/emoji-atlas.png" ]; then
    echo "打开图片查看..."
    open "$OUTPUT_DIR/emoji-atlas.png" 2>/dev/null || echo "无法自动打开，请手动查看: $OUTPUT_DIR/emoji-atlas.png"
fi

echo ""
echo "💡 提示:"
echo "  - 如果 emoji-atlas.png 显示彩色 emoji → 图集渲染正常"
echo "  - 如果 emoji-atlas.png 全黑或空 → 光栅化失败"
echo "  - 对比 glyph-atlas.png 看灰度文字是否正常"
echo ""
