#!/bin/sh
# Commit and push the probe's dumped PNGs so Person 2's agent can run the live harnesses on them
# (Tests/XRealVisionTests/LiveFrameHandDetectionTests, Tests/XRealMirrorAppTests/LiveFrameFretboardTests).
# Run right after a glasses capture:
#
#   scripts/push-live-frames.sh /path/to/probe-out                       # → live-probe-frames/
#   scripts/push-live-frames.sh /path/to/probe-out setup-still "note"    # → live-probe-frames/setup-still/
#
# Dataset names used by the fretboard plan: setup-still, play, distance-30, distance-50, distance-80, occluded,
# clutter. The optional note (what was done during the capture) goes into run-info.txt.
# PUSH_LIVE_FRAMES_DRY_RUN=1 copies and stamps the frames but skips every git step.
# Person 2's agent instructions: docs/live-verification/person2-agent.md
set -eu

OUT_DIR="${1:?usage: scripts/push-live-frames.sh <probe-out-dir> [dataset-name] [note]}"
NAME="${2:-}"
NOTE="${3:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "$NAME" ]; then
    case "$NAME" in
        *[!A-Za-z0-9_-]*) echo "dataset name may only contain letters, digits, - and _: '$NAME'" >&2; exit 1 ;;
    esac
    DEST="$REPO_ROOT/live-probe-frames/$NAME"
else
    DEST="$REPO_ROOT/live-probe-frames"
fi

if ! ls "$OUT_DIR"/*.png >/dev/null 2>&1; then
    echo "no PNGs found in $OUT_DIR" >&2
    exit 1
fi

mkdir -p "$DEST"
rm -f "$DEST"/*.png "$DEST"/run-info.txt "$DEST"/detection-report.txt
cp "$OUT_DIR"/*.png "$DEST"/
[ -f "$OUT_DIR/detection-report.txt" ] && cp "$OUT_DIR/detection-report.txt" "$DEST"/

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    echo "$STAMP"
    echo "frames: $(ls "$DEST"/*.png | wc -l | tr -d ' ')"
    echo "source: $OUT_DIR"
    [ -n "$NAME" ] && echo "dataset: $NAME"
    [ -n "$NOTE" ] && echo "note: $NOTE"
    true
} > "$DEST/run-info.txt"

if [ "${PUSH_LIVE_FRAMES_DRY_RUN:-}" = "1" ]; then
    echo "dry run: frames in $DEST, no git steps"
    exit 0
fi

cd "$REPO_ROOT"
git pull --ff-only origin main
git add -f "$DEST"
if git diff --cached --quiet; then
    echo "nothing new to push (frames identical to the last run?)" >&2
    exit 1
fi
git commit -m "live probe frames${NAME:+ ($NAME)}: glasses run $STAMP"
git push origin main
echo "pushed. Person 2's agent: pull main and follow docs/live-verification/person2-agent.md"
