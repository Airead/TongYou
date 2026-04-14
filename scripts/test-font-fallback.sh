#!/bin/bash

# 字体回退测试脚本
# 运行方式: ./scripts/test-font-fallback.sh
# 这会在当前终端输出各种需要字体回退的字符

echo "========================================"
echo "TongYou 字体回退链测试"
echo "========================================"
echo ""

echo "1. ASCII 字符 (应该使用主字体):"
echo "   Hello World 123"
echo ""

echo "2. Emoji (应该使用 Apple Color Emoji):"
echo "   👍 👋 🎉 ❤️ 🚀"
echo "   👨‍👩‍👧‍👦 (家庭 emoji ZWJ 序列)"
echo "   👋🏻 (肤色修饰 emoji)"
echo "   🇨🇳 (国旗 emoji)"
echo ""

echo "3. CJK 字符 (应该回退到 PingFang/Hiragino):"
echo "   中文测试 日本語テスト 한국어"
echo "   こんにちは 你好 안녕하세요"
echo ""

echo "4. 数学符号 (应该回退到 STIX/系统数学字体):"
echo "   ∑ ∏ ∫ √ ∞ ≠ ≤ ≥ ±"
echo "   ∀ ∃ ∈ ∉ ⊆ ⊂ ∪ ∩"
echo "   α β γ δ ε θ λ μ π σ"
echo ""

echo "5. 货币符号:"
echo "   $ € £ ¥ ₹ ₽ ₩"
echo ""

echo "6. 箭头和几何:"
echo "   ← ↑ → ↓ ↔ ↕ ↗ ↘ ↙ ↖"
echo "   ■ ▲ ● ◆ ★ ☆"
echo ""

echo "7. 技术符号 (Powerline/Nerd Font 风格):"
echo "   ➜ ✗ ✓ ⚡ ⚙️ 🐳"
echo ""

echo "8. 阿拉伯语 (Arabic):"
echo "   مرحبا بالعالم"
echo ""

echo "9. 印地语 (Hindi):"
echo "   नमस्ते दुनिया"
echo ""

echo "10. 希腊语 (Greek):"
echo "    Γειά σου Κόσμε"
echo ""

echo "11. 俄语 (Cyrillic):"
echo "    Привет мир"
echo ""

echo "12. 泰语 (Thai):"
echo "    สวัสดีชาวโลก"
echo ""

echo "========================================"
echo "如果以上所有字符都能正确显示（而不是 □ 或空白），"
echo "说明字体回退链工作正常！"
echo "========================================"
