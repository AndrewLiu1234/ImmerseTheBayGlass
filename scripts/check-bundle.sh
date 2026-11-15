#!/bin/bash
# Delivery gate: rebuilds the bundle and fails loudly (non-zero exit + FAIL: line) if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle-app.sh || { echo "FAIL: bundle-app.sh failed"; exit 1; }
APP=dist/XRealMirror.app
[ -d "$APP" ] || { echo "FAIL: $APP missing"; exit 1; }
[ -x "$APP/Contents/MacOS/XRealMirror" ] || { echo "FAIL: app executable missing"; exit 1; }
[ -x "$APP/Contents/MacOS/XRealProbe" ] || { echo "FAIL: bundled probe missing"; exit 1; }
USAGE=$(plutil -extract NSCameraUsageDescription raw "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$USAGE" ] || { echo "FAIL: NSCameraUsageDescription missing from Info.plist"; exit 1; }
# Capture output first, then grep: `cmd | grep -q` under pipefail can fail on SIGPIPE even when the line is there.
SIG=$(codesign -dv "$APP" 2>&1 || true)
grep -q "Signature=adhoc" <<<"$SIG" || { echo "FAIL: ad-hoc signature missing"; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "FAIL: codesign --verify failed"; exit 1; }
PROBE_OUT=$("$APP/Contents/MacOS/XRealProbe" --devices 2>&1) || { echo "FAIL: probe --devices exited non-zero"; echo "$PROBE_OUT"; exit 1; }
grep -q '^XREAL PROBE$' <<<"$PROBE_OUT" || { echo "FAIL: probe smoke failed (no XREAL PROBE banner)"; echo "$PROBE_OUT"; exit 1; }
echo "BUNDLE CHECK PASS"
