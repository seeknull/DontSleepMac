#!/usr/bin/env bash
# Build DontSleepMac.app from source. No dependencies beyond Xcode command-line tools.
#
#   ./build.sh               this Mac's architecture only (what install.sh uses)
#   ./build.sh --universal   one binary for Apple silicon and Intel, macOS 13+ (what release.sh uses)
set -euo pipefail
cd "$(dirname "$0")"

APP="DontSleepMac.app"
VERSION="1.0"       # CFBundleShortVersionString and CFBundleVersion; release.sh names the zip after it
MIN_MACOS="13.0"    # LSMinimumSystemVersion, and the deployment target of --universal

UNIVERSAL=0
case "${1:-}" in
  "")          ;;
  --universal) UNIVERSAL=1 ;;
  *)           echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac

echo "Building $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile
BIN="$APP/Contents/MacOS/DontSleepMac"
if [ "$UNIVERSAL" = 1 ]; then
  # One slice per architecture, then join them into a single binary.
  for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" main.swift -o "$BIN-$ARCH"
  done
  lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
  rm "$BIN-arm64" "$BIN-x86_64"
else
  swiftc -O main.swift -o "$BIN"
fi

# App icon
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DontSleepMac</string>
  <key>CFBundleDisplayName</key><string>DontSleepMac</string>
  <key>CFBundleIdentifier</key><string>com.seeknull.dontsleepmac</string>
  <key>CFBundleExecutable</key><string>DontSleepMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
</dict>
</plist>
PLIST

echo "Done -> $APP ($(lipo -archs "$BIN"))"
echo "Run:  open $APP"
