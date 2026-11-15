# XRealMirror: agent notes

A macOS app that mirrors both XREAL Air 2 Ultra tracking cameras live, side by side, draws a 21-landmark hand skeleton
over each eye pane (stage 2), and triangulates both eyes into live 3-D hands shown in a SceneKit pane (stage 3, the
user's direction Sun 2026-11-15; app lane, no spec doc yet). Nothing else: no webcam fallback, recording, gestures or
MediaPipe. If a task drifts into those, stop and ask.
Specs (authoritative: contract, constants, hazards): `docs/superpowers/specs/2026-11-14-xrealmirror-design.md` (stage 1)
and `docs/superpowers/specs/2026-11-15-hand-tracking-design.md` (stage 2; supersedes stage 1 only on hand tracking/overlays).

## Layout

- `Sources/XRealVision/`: library. `XRealFrameDecoder` (pure byte decode), `StereoPairer`, `StereoCamera` (AVFoundation).
- `Sources/XRealMirrorApp/`: SwiftUI app (`AppModel` owns permission + capture; `EyeView` sets `layer.contents` directly).
  3-D hands: `StereoCalibration` (fisheye lenses + stereo extrinsics, from xr-gate's Air 2 Ultra camchain — another
  unit, a start value) → `StereoHandFusion` (pairs hands across eyes by geometry, never Vision chirality; triangulates
  21 joints) → `Hands3DScene`/`Hands3DView` (SceneKit, 1€-smoothed).
- Fretboard (stage 4, spec `docs/superpowers/specs/2026-11-15-fretboard-tracking-design.md`): Person 1's
  `StereoMarkerTracker` (ArUco 7/8/9) → `MarkerPoseEstimator` (stereo / one eye + 60 mm) → `GuitarTracker`
  (`GuitarModel`: `.nominalF600` until `GuitarSetup` runs on a real capture) → `FretboardProjection` (2-D overlay per eye,
  3-D pane) + `FingerOnFretboard` (fingertip → string / fret / height). Synthetic stereo fixtures:
  `fixtures/markers-synthetic/` (regenerate: `GENERATE_MARKER_FIXTURES=1 swift test --filter MarkerFixtureTests`).
- Live-data checks (skip without the env var): `XREAL_PROBE_PNGS=<dir> swift test --filter LiveFrame`.
- `Sources/XRealProbe/`: CLI that verifies the live pipeline and dumps PNGs.
- `Resources/Info.plist`, `scripts/bundle-app.sh`, `scripts/check-bundle.sh`: bundle and delivery gate.

## Lane ownership (do not cross)

| Path | Owner |
|---|---|
| `Sources/XRealVision/**`, `Tests/XRealVisionTests/**` | Person 1 (Vision Core) |
| `Sources/XRealMirrorApp/**`, `Tests/XRealMirrorAppTests/**`, `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md` | Person 2 (App, Overlay & Probe) |
| `Package.swift`, `.gitignore`, `docs/**` | Coordinator |

Edit only your own lane. If a change needs another lane's file, finish your task, report it, and let that owner make the change.
The interface contract in the spec is the single source of truth. Never rename or re-signature it without asking.

## Commands

- Unit tests: `swift test`
- Bundle: `./scripts/bundle-app.sh` → `dist/XRealMirror.app` · gate: `./scripts/check-bundle.sh` (must print `BUNDLE CHECK PASS`)
- Probe (real camera): `dist/XRealMirror.app/Contents/MacOS/XRealProbe` (`--devices` to list). Never `swift run XRealProbe`
  for the real camera, because camera TCC only applies inside the bundle.

## Hazards (verbatim from the spec)

- Never set `videoSettings` on the capture output (raw payload required).
- Camera ID lives at `+0x3A`, not `+0x3B`.
- Transpose ≠ rotation (mirror trap). Left = rotate 90° CCW, right = rotate 90° CW.
- Skip the first 6 frames; brightness settles over ~25 frames.
- Pairing map clears when `pending.count > 8`.
- Sequence steps 256 per pair (wraps every 256 pairs).
- The probe must run from the bundled `.app` path for TCC; unbundled `swift run` camera access is flaky.
- The reorderMap is guarded by a permutation unit test: if it fails, stop and report. Don't invent a value.

## Dead ends (do not retry)

Plain 640×480 with 1280-byte header; stacked 640×240 frames; row deinterleaving; field splitting; serpentine scan;
YUY2 plane separation; RAW10 unpacking; column-major transpose.
