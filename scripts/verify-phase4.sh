#!/bin/bash
set -e

echo "==============================================="
echo "  Phase 4 CoreText Shaping Verification"
echo "==============================================="
echo ""

echo "--- 1. Ligature Test ---"
echo "If shaping works, 'fi' and 'fl' should appear as connected ligatures:"
printf "office\nrefine\nfluffy\ncaffeine\n"
echo ""

echo "--- 2. Complex Script Test ---"
echo "Arabic and Hindi should render as connected/flowing glyphs:"
echo "مرحبا (Arabic)"
echo "नमस्ते (Hindi)"
echo "你好 (Chinese - no shaping needed, but should still display)"
echo ""

echo "--- 3. Emoji Sequence Test ---"
echo "These should render as single unified icons, not broken pieces:"
echo "👨‍👩‍👧‍👦  (family, should be one icon)"
echo "🏳️‍🌈  (rainbow flag, should be one icon)"
echo "👋🏽  (waving hand + medium skin tone, should be one icon)"
echo "🇨🇳  (China flag, should be one icon)"
echo ""

echo "--- 4. Unit Tests ---"
echo "Running CoreTextShaperTests..."
cd "$(dirname "$0")/.."
xcodebuild test -scheme TongYou -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TongYouTests/CoreTextShaperTests 2>&1 | tail -20
echo ""

echo "==============================================="
echo "  Verification complete."
echo "==============================================="
echo ""
echo "How to judge results:"
echo "  - Ligatures: 'fi' looks like one connected glyph -> OK"
echo "  - Arabic/Hindi: letters flow together, not isolated blocks -> OK"
echo "  - Emoji sequences: single icon, not multiple fragments -> OK"
echo "  - Tests: all passed -> OK"
