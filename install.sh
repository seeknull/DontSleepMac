#!/usr/bin/env bash
# Build DontSleepMac and install it to /Applications.
# After this, launch it any time with  Cmd+Space → "Don't Sleep".
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "Installing to /Applications ..."
rm -rf /Applications/DontSleepMac.app
cp -R DontSleepMac.app /Applications/

# Refresh Spotlight/Launch Services so it's findable immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/DontSleepMac.app 2>/dev/null || true

open /Applications/DontSleepMac.app

echo ""
echo "✅ Installed. It's running now — look for the eye in your menu bar."
echo "   Launch any time:  Cmd+Space → \"Don't Sleep\""
