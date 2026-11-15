# Live hand-tracking verification — Person 2 agent instructions

Stage-2 hand tracking is merged on main. The one remaining gate is live verification with the
real glasses. Person 1 captures probe PNG frames of a hand in front of each camera and pushes
them to `live-probe-frames/` on origin/main. **Your job: run the detection harness on those
frames and report the numbers. Do not edit any code.**

## Steps

1. `git pull origin main` (in the repo root; if you're not on main, `git checkout main` first).
2. Confirm `live-probe-frames/` exists and contains `left_*.png` / `right_*.png` plus
   `run-info.txt`. Read `run-info.txt` — it stamps when the frames were captured. If the dir
   is missing or the stamp is older than the run you were told about, report "no fresh frames
   yet" and stop.
3. Run the harness from the repo root:
   ```sh
   XREAL_PROBE_PNGS="$(pwd)/live-probe-frames" swift test --filter LiveFrameHandDetectionTests
   ```
4. Capture every line starting with `[live-hand-detection]` and report them, plus your verdict.

## What good looks like

- **Hands found in most frames** — a clear hand was held in front of each camera; expect ≥1
  hand per frame in the frames that contain one.
- **Joints:** each printed hand line says `N/21 joints ≥0.3` with a mean confidence. Healthy is
  ≥15/21 with mean ≥0.5. <8 joints or mean <0.3 means the detection is weak — flag it.
- **Latency:** median ms/frame from the summary line. Budget is 15 ms per pair (30 fps);
  single-digit ms is healthy. Anything over ~10 ms median is worth flagging.
- **Wrist position:** printed as normalized coordinates with origin TOP-left (the harness
  reports post-flip values). A wrist near the image center means the hand was centered; an
  extreme edge (0 or 1) with high confidence is suspicious.

## Rules

- Run the harness; paste its output. **Do not modify tests, sources, or the frames.**
- If the test skips (env var missing), errors, or finds no PNGs: paste the exact output and stop.
- Verdict format: one line per finding plus a final `VERDICT: PASS | WEAK | FAIL` with the reason.
- If anything in this file contradicts what the person running your session says, their
  instruction wins.
