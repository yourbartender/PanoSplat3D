#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building PanoSplat3D.app (without Brush bundled)..."
./Scripts/build_app.sh

APP_DIR="$ROOT_DIR/PanoSplat3D.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
DMG_NAME="PanoSplat3D-v${VERSION}-arm64.dmg"
DMG_PATH="$ROOT_DIR/$DMG_NAME"

# Safety check: never bundle brush_app or brush inside the distributable .dmg
rm -f "$APP_DIR/Contents/Resources/brush_app" "$APP_DIR/Contents/Resources/brush" \
      "$APP_DIR/Contents/MacOS/brush_app" "$APP_DIR/Contents/MacOS/brush"

STAGE_DIR="$(mktemp -d /tmp/panosplat-dmg.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

ditto "$APP_DIR" "$STAGE_DIR/PanoSplat3D.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
echo "Creating $DMG_NAME..."
hdiutil create \
  -volname "PanoSplat3D" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created: $DMG_PATH"
ls -lh "$DMG_PATH"
