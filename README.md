# XRealMirror

A macOS app that shows, live and side by side, what the two tracking cameras of an **XREAL Air 2 Ultra** see (left `0x20`, right `0x21`), correctly oriented. On top of that it tracks your hands: a 2-D skeleton over each eye, and a **3-D pane** that combines both eyes into live 3-D hands (position in centimetres from the glasses, plus every finger joint). Drag the 3-D pane to orbit, scroll to zoom, double-click to reset; ⌘3 shows or hides it.

## Requirements

- XREAL Air 2 Ultra plugged into the Mac over USB-C
- macOS 15 or later, Swift 6 toolchain (Xcode 26+)

## Build and run

```bash
./scripts/bundle-app.sh        # builds release, assembles + ad-hoc signs dist/XRealMirror.app
open dist/XRealMirror.app
```

`./scripts/check-bundle.sh` rebuilds the bundle and checks it (camera usage string, ad-hoc signature, bundled probe smoke). It prints `BUNDLE CHECK PASS`, or a `FAIL:` line and a non-zero exit.

## First run: camera permission

macOS asks for camera access the first time the app opens. If you declined, or the panes stay empty with a "permission denied" status, go to **System Settings → Privacy & Security → Camera**, turn on **XRealMirror**, then press **Retry** (⌘R) in the app.

## The probe

`XRealProbe` checks the whole decode pipeline against the plugged-in glasses and writes sample PNGs. Run it from inside the app bundle (not with `swift run`):

**Permission note:** when you start the probe from a shell, macOS checks camera permission for the *terminal app* (Terminal, iTerm, …), not for XRealMirror. Enable your terminal under System Settings → Privacy & Security → Camera and reopen it. `tccutil reset Camera com.apple.Terminal` brings the prompt back.

```bash
dist/XRealMirror.app/Contents/MacOS/XRealProbe --devices    # list external video devices, exit 0
dist/XRealMirror.app/Contents/MacOS/XRealProbe              # capture 40 frames, verify, dump PNGs
#   options: --frames N (default 40, includes the 6 warmup frames the camera skips) · --out DIR · --timeout SEC
```

Example output:

```
XREAL PROBE
  device: UVC Camera VendorID_13080 ProductID_1062 (UVC Camera VendorID_13080 ProductID_1062)
  frames decoded: 34 / 34 received (all 308,480-byte frames → 307200-byte images)
  cameras seen: 0x20 x17, 0x21 x17
  sequence deltas == 256: 32/32 same-ID pairs
  first-frame zero fraction: 0.00, 0.00, 0.00
  PNGs: /tmp/xreal-probe/left_0.png … (3 pairs)
PROBE PASS
```

The PNGs (`left_0.png`, `right_0.png`, … in `/tmp/xreal-probe/`) are for a human to look at: orientation is a visual fact, so check that both eyes are upright and not mirrored.

Exit codes: `0` = `PROBE PASS`, `1` = `PROBE FAIL: …` or `NO XREAL FOUND`, `2` = bad arguments.

## Troubleshooting

- **The first second or so is dark or flickers.** That's sensor warmup. The camera drops the first 6 frames, and auto-exposure settles over about 25 frames.
- **`NO XREAL FOUND` / "not found" overlay.** Check the USB-C cable and port. Look for `UVC Camera VendorID_13080 ProductID_1062` in System Information → USB, or with `XRealProbe --devices`.
- **Permission is stuck.** Run `tccutil reset Camera com.immersetebay.xrealmirror`, then open the app again to get the prompt back.

## Layout

| Path | What |
|---|---|
| `Sources/XRealVision/` | decode core (descramble, rotate, pair) + `StereoCamera` capture wrapper |
| `Tests/XRealVisionTests/` | unit tests for the decode core and pairer |
| `Sources/XRealMirrorApp/` | the SwiftUI app |
| `Sources/XRealProbe/` | the hardware verification CLI |
| `Resources/Info.plist`, `scripts/` | bundle metadata and build/check scripts |
| `docs/superpowers/` | design spec and implementation plans |
