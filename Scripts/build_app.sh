#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building PanoSplat3D (Release arm64)..."
swift build -c release

APP_DIR="$ROOT_DIR/PanoSplat3D.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Shaders" "$APP_DIR/Contents/Resources/Sounds"

cp ".build/arm64-apple-macosx/release/PanoSplat3D" "$APP_DIR/Contents/MacOS/PanoSplat3D"
chmod +x "$APP_DIR/Contents/MacOS/PanoSplat3D"

cp Sources/PanoSplat3DCore/Resources/Shaders/*.metal "$APP_DIR/Contents/Resources/Shaders/"
if [ -d "Sources/PanoSplat3DCore/Resources/Sounds" ]; then
  cp Sources/PanoSplat3DCore/Resources/Sounds/* "$APP_DIR/Contents/Resources/Sounds/"
fi
if [ -f "Assets/AppIcon.icns" ]; then
  cp "Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Precompile all Metal shaders into default.metallib for instant startup
if xcrun -find metal >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d /tmp/panosplat-metal.XXXXXX)"
  AIR_FILES=()
  for shader in Sources/PanoSplat3DCore/Resources/Shaders/*.metal; do
    base="$(basename "$shader" .metal)"
    air="$TMP_DIR/${base}.air"
    xcrun metal -c "$shader" -o "$air"
    AIR_FILES+=("$air")
  done
  xcrun metallib "${AIR_FILES[@]}" -o "$APP_DIR/Contents/Resources/default.metallib"
  rm -rf "$TMP_DIR"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PanoSplat3D</string>
    <key>CFBundleExecutable</key>
    <string>PanoSplat3D</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.panosplat3d.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PanoSplat3D</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.13.1</string>
    <key>CFBundleVersion</key>
    <string>35</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>360° Panorama Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
                <string>public.png</string>
                <string>com.ilm.openexr-image</string>
                <string>public.tiff</string>
                <string>public.heic</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>jpg</string>
                <string>jpeg</string>
                <string>png</string>
                <string>exr</string>
                <string>tif</string>
                <string>tiff</string>
                <string>heic</string>
            </array>
        </dict>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
touch "$APP_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
echo "Built and signed $APP_DIR"
