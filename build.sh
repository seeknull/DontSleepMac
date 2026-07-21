#!/usr/bin/env bash
# Build DontSleepMac.app from source. No dependencies beyond Xcode command-line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="DontSleepMac.app"
echo "Building $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile
swiftc -O main.swift -o "$APP/Contents/MacOS/DontSleepMac"

# App icon
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DontSleepMac</string>
  <key>CFBundleDisplayName</key><string>DontSleepMac</string>
  <key>CFBundleIdentifier</key><string>com.seeknull.dontsleepmac</string>
  <key>CFBundleExecutable</key><string>DontSleepMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

echo "Done -> $APP"
echo "Run:  open $APP"
