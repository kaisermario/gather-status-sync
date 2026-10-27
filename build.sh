#!/bin/zsh
# Builds StatusSync.app and installs it to /Applications.
# Note: the app is ad-hoc signed, so after every rebuild macOS asks for the
# Accessibility permission again (System Settings → Privacy & Security → Accessibility).
set -euo pipefail
cd "${0:A:h}"

swift build -c release
app=build/StatusSync.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/StatusSync "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
rm -rf build/AppIcon.iconset
.build/release/StatusSync --render-app-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

pkill -x StatusSync || true
rm -rf /Applications/StatusSync.app
cp -R "$app" /Applications/
echo "Installed /Applications/StatusSync.app"
