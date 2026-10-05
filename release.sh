#!/usr/bin/env bash
# Build the downloadable release of DontSleepMac.
#
#   ./release.sh
#
# Writes two files to dist/ (gitignored), ready to attach to a GitHub release:
#   DontSleepMac-<version>.zip          DontSleepMac.app — universal (arm64 + x86_64),
#                                       macOS 13 or later, ad-hoc signed
#   DontSleepMac-<version>.zip.sha256   its checksum, in `shasum -a 256` format
#
# <version> is the one build.sh writes into Info.plist. A downloader checks the
# zip with:  shasum -a 256 -c DontSleepMac-<version>.zip.sha256
#
# Steps: ./build.sh --universal, check both slices are there, ad-hoc sign the
# bundle, zip it with ditto, write the checksum.
# The signature is ad hoc because there is no Apple Developer ID: the app is not
# notarized, so macOS asks the user to approve its first launch
# (System Settings → Privacy & Security → Open Anyway).
#
# Needs only Xcode command-line tools. To install on this Mac, use ./install.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="DontSleepMac.app"
BIN="$APP/Contents/MacOS/DontSleepMac"

./build.sh --universal
lipo "$BIN" -verify_arch arm64 x86_64        # fails if a slice is missing

codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="DontSleepMac-$VERSION.zip"

mkdir -p dist
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")

echo ""
echo "dist/$ZIP  ($(lipo -archs "$BIN"); $(stat -f %z "dist/$ZIP") bytes)"
echo "dist/$ZIP.sha256:"
cat "dist/$ZIP.sha256"
