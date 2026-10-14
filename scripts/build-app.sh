#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Invalid VERSION" >&2; exit 1; fi
swift build -c release --arch arm64 --disable-sandbox
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="dist/PathBoard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PathBoard" "$APP/Contents/MacOS/PathBoard"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.mz-gen-labs.PathBoard</string>
<key>CFBundleName</key><string>PathBoard</string>
<key>CFBundleDisplayName</key><string>PathBoard</string>
<key>CFBundleExecutable</key><string>PathBoard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift dist
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
