#!/bin/bash
# Builds a release HRTFToSOFA.app (and the hrtf2sofa CLI) into ./dist
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/HRTFToSOFA.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HRTFToSOFA" "$APP/Contents/MacOS/HRTFToSOFA"
cp "$BIN/hrtf2sofa" dist/hrtf2sofa
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HRTFToSOFA</string>
  <key>CFBundleDisplayName</key><string>HRTF to SOFA</string>
  <key>CFBundleIdentifier</key><string>local.hrtftosofa</string>
  <key>CFBundleExecutable</key><string>HRTFToSOFA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP and dist/hrtf2sofa"
