# XRealMirror: agent notes

A macOS app that mirrors both XREAL Air 2 Ultra tracking cameras live, side by side. Nothing else: no hand tracking,
calibration, 3D, webcam fallback, recording or overlays. If a task drifts into those, stop and ask.
Spec (authoritative: contract, constants, hazards): `docs/superpowers/specs/2026-11-14-xrealmirror-design.md`.

## Layout

- `Sources/XRealVision/`: library. `XRealFrameDecoder` (pure byte decode), `StereoPairer`, `StereoCamera` (AVFoundation).
- `Sources/XRealMirrorApp/`: SwiftUI app (`AppModel` owns permission + capture; `EyeView` sets `layer.contents` directly).
- `Sources/XRealProbe/`: CLI that verifies the live pipeline and dumps PNGs.
- `Resources/Info.plist`, `scripts/bundle-app.sh`, `scripts/check-bundle.sh`: bundle and delivery gate.

## Lane ownership (do not cross)

| Path | Owner |
|---|---|
| `Sources/XRealVision/**`, `Tests/XRealVisionTests/**` | Person 1 (Vision Core) |
| `Sources/XRealMirrorApp/**`, `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md` | Person 2 (App & Probe) |
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
