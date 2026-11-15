#!/bin/sh
# Commit and push the probe's dumped PNGs so Person 2's agent can run the live
# hand-detection harness (Tests/XRealVisionTests/LiveFrameHandDetectionTests) on them.
# Run right after a glasses capture:
#
#   scripts/push-live-frames.sh /path/to/probe-out
#
# The frames land in live-probe-frames/ on origin/main, with run-info.txt stamped
# with the run time. Person 2's agent instructions: docs/live-verification/person2-agent.md
set -eu

OUT_DIR="${1:?usage: scripts/push-live-frames.sh <probe-out-dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/live-probe-frames"

mkdir -p "$DEST"
rm -f "$DEST"/*.png "$DEST"/run-info.txt "$DEST"/detection-report.txt
cp "$OUT_DIR"/*.png "$DEST"/
[ -f "$OUT_DIR/detection-report.txt" ] && cp "$OUT_DIR/detection-report.txt" "$DEST"/

if ! ls "$DEST"/*.png >/dev/null 2>&1; then
    echo "no PNGs found in $OUT_DIR" >&2
    exit 1
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    echo "$STAMP"
    echo "frames: $(ls "$DEST"/*.png | wc -l | tr -d ' ')"
    echo "source: $OUT_DIR"
} > "$DEST/run-info.txt"

cd "$REPO_ROOT"
git pull --ff-only origin main
git add -f live-probe-frames
if git diff --cached --quiet; then
    echo "nothing new to push (frames identical to the last run?)" >&2
    exit 1
fi
git commit -m "live probe frames: glasses run $STAMP"
git push origin main
echo "pushed. Person 2's agent: pull main and follow docs/live-verification/person2-agent.md"
