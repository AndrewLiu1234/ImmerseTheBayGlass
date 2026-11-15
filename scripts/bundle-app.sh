#!/bin/bash
# Builds dist/XRealMirror.app (release, ad-hoc signed). The probe ships inside the bundle on purpose:
# macOS keys camera permission to the signed bundle, so the probe inherits the app's TCC grant.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/XRealMirror.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/XRealMirrorApp" "$APP/Contents/MacOS/XRealMirror"
cp "$BIN/XRealProbe"     "$APP/Contents/MacOS/XRealProbe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP"
echo "Built $APP"
