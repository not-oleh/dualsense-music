#!/bin/sh
# Builds "DualSense Music.app", the menu bar app, in this folder.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="DualSense Music.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/dualsense-music "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.not-oleh.dualsense-music</string>
<key>CFBundleName</key><string>DualSense Music</string>
<key>CFBundleExecutable</key><string>dualsense-music</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - -f "$APP"
echo "Built $APP. Open it, or move it to /Applications first."
