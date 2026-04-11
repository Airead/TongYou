#!/usr/bin/env bash
# Package an already-built TongYou.app into a styled DMG installer.
# Usage:
#   ./scripts/build-dmg.sh              # Use version from project
#   ./scripts/build-dmg.sh [version]    # Explicit version
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TongYou"
APP_PATH="$BUILD_DIR/Release/$APP_NAME.app"

# Check that the .app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found."
    echo "Run 'make build-release' first."
    exit 1
fi

# Check that create-dmg is installed
if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

# Read version from Xcode project
PROJECT_VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' \
    "$PROJECT_DIR/TongYou.xcodeproj/project.pbxproj" | head -1 | xargs)

# Version: explicit arg > git tag > project setting
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "")
fi
if [ -z "$VERSION" ]; then
    VERSION="$PROJECT_VERSION"
fi

DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}-arm64.dmg"

cd "$PROJECT_DIR"

# Check that DMG resources exist
if [ ! -f "resources/dmg-background.png" ] || [ ! -f "resources/dmg-volume.icns" ]; then
    echo "ERROR: DMG resources not found. Run 'make dmg-resources' first."
    exit 1
fi

echo "==> Creating DMG for $APP_NAME v${VERSION}..."

# Remove previous DMG if exists (create-dmg won't overwrite)
rm -f "$DMG_PATH"
create-dmg \
    --volname "$APP_NAME" \
    --volicon "$PROJECT_DIR/resources/dmg-volume.icns" \
    --background "$PROJECT_DIR/resources/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 175 190 \
    --app-drop-link 425 190 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "==> DMG complete!"
echo "    App: $APP_PATH ($APP_SIZE)"
echo "    DMG: $DMG_PATH ($DMG_SIZE)"
