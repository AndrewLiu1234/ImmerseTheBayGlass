# XRealMirror — Lane 2 (App & Probe) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The visible deliverable: a double-clickable `XRealMirror.app` showing both XREAL camera feeds live, plus the bundled `XRealProbe` CLI that proves the pipeline against real hardware, plus the repo docs.

**Architecture:** SwiftUI app shell over Lane 1's `StereoCamera` — an `AppModel` owns capture and permission, two CALayer-backed `NSView` panes render the latest `StereoFrame` (no SwiftUI image diffing per frame), and a status bar shows state and rate. `XRealProbe` reuses the exact same capture path and adds raw-layout checks + PNG dumps. A bundle script assembles and ad-hoc signs the `.app`; the probe ships *inside* that bundle so macOS camera TCC applies to it.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit (`NSViewRepresentable`), AVFoundation, CoreGraphics, bash (bundle scripts), `plutil`/`codesign`.

**Spec:** `docs/superpowers/specs/2026-11-14-xrealmirror-design.md` — the interface contract, constants, and hazards in it are authoritative. Read it first. Lane 1 is building `XRealVision` in parallel; the contract there is already fixed, so code against it as written (a red build because Lane 1 hasn't landed yet is fine — do not "fix" Lane 1's code; if the package doesn't compile and Lane 1's placeholder files are still present, that is expected mid-flight, wait and rebuild).

## Global Constraints

- Code against the design doc's Interface contract exactly. In particular: `StereoCamera`, `StereoCameraDelegate` (delivery on a private capture queue — hop to main yourself), `StereoFrame`, `RawEyeFrame`, `CameraID`, `XRealFrameDecoder.makeEyeImage`, `DecodedFrame`, `FrameLayout`.
- Own only `Sources/XRealMirrorApp/**`, `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md`. Never touch Lane 1's paths (`Sources/XRealVision/**`, `Tests/**`) or `Package.swift` / `.gitignore`. If a change seems to need them, stop and report.
- UI state changes only on the main thread; capture callbacks arrive on a background queue.
- Swift 6 language mode: concurrency-safe code; where a queue boundary carries `CGImage`/`StereoFrame`, annotate `@unchecked Sendable` with a one-line comment.
- **Never set `videoSettings`** anywhere (it is never set here anyway — this lane doesn't configure the capture output; the warning exists so a "helpful" addition doesn't break the raw payload).
- Every check that guards a deliverable lives in a script that fails loudly (non-zero exit + `FAIL:` line) — no hand-run checks that can be forgotten.
- The probe must run from the bundled path `dist/XRealMirror.app/Contents/MacOS/XRealProbe` for TCC. Document that; never tell users to `swift run XRealProbe` for the real camera.
- Mirror-only scope: no hand tracking, calibration, recording, or overlays. If it looks like scope creep, stop and report.
- Work on `main` in the shared working tree; commit per task; if `git` reports `index.lock`, wait and retry. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

These are the five ways this lane most plausibly ships a broken experience; each has its gate named.

1. Glasses unplugged → the app must show a clear "plug in" state and not crash; the probe must print device list and exit 1 with `NO XREAL FOUND`. Gate: Task 7 probe behavior (verified live) and Task 5 missing-state.
2. Camera permission not granted → app shows explicit instructions; the `NSCameraUsageDescription` key's presence is asserted by `scripts/check-bundle.sh`. Gate: Task 6.
3. Invisible window when run unbundled during dev → explicit `NSApplication` activation policy `.regular` + activate; verified by launching. Gate: Task 5 verification step.
4. Probe run unbundled and fails on TCC → `check-bundle.sh` executes the *bundled* probe with `--devices` and requires exit 0. Gate: Task 6.
5. Display stutter/lag at ~30 pairs/s → panes set `layer.contents` directly (no per-frame SwiftUI diffing); live rate shown in the status bar. Gate: Task 5 design + live check.

## File Map

- Create: `Sources/XRealMirrorApp/XRealMirrorApp.swift`, `AppModel.swift`, `EyeView.swift`, `ContentView.swift`
- Delete: `Sources/XRealMirrorApp/main.swift` (placeholder — cannot coexist with `@main`)
- Create: `Sources/XRealProbe/main.swift` (replaces the placeholder of the same name)
- Create: `Resources/Info.plist`, `scripts/bundle-app.sh`, `scripts/check-bundle.sh`, `README.md`, `CLAUDE.md`

---

### Task 5: The mirror app (SwiftUI shell + two live panes)

**Files:**
- Create: `Sources/XRealMirrorApp/XRealMirrorApp.swift`, `AppModel.swift`, `EyeView.swift`, `ContentView.swift`
- Delete: `Sources/XRealMirrorApp/main.swift`

**Interfaces:**
- Consumes: `StereoCamera`, `StereoCameraDelegate`, `StereoFrame`, `RawEyeFrame`, `CameraID`, `XRealCameraError`.
- Produces: the app target `XRealMirrorApp` (bundled in Task 6).

- [ ] **Step 1: Write `Sources/XRealMirrorApp/AppModel.swift`**

```swift
import AppKit
import AVFoundation
import XRealVision

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum Status: Equatable { case searching, running, missing(String), permissionDenied }

    @Published var status: Status = .searching
    @Published var latestFrame: StereoFrame?
    @Published var pairsPerSecond: Double = 0

    private let camera = StereoCamera()
    private var pairCounter = 0
    private var rateTimer: Timer?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.beginCapture() } else { self.status = .permissionDenied }
                }
            }
        case .denied, .restricted, @unknown default:
            status = .permissionDenied
        }
    }

    func stop() { camera.stop(); rateTimer?.invalidate(); rateTimer = nil }

    private func beginCapture() {
        guard StereoCamera.findXRealDevice() != nil else {
            status = .missing("No XREAL Air 2 Ultra found. Plug in the glasses via USB-C, then Retry.")
            return
        }
        camera.delegate = self
        do {
            try camera.start()
            status = .running
            rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pairsPerSecond = Double(self.pairCounter)
                    self.pairCounter = 0
                }
            }
        } catch {
            status = .missing(error.localizedDescription)
        }
    }
}

extension AppModel: StereoCameraDelegate {
    // Called on the camera's capture queue — hop to main for UI.
    nonisolated func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame) {
        Task { @MainActor in
            self.latestFrame = frame
            self.pairCounter += 1
        }
    }
}
```

- [ ] **Step 2: Write `Sources/XRealMirrorApp/EyeView.swift`**

```swift
import AppKit
import SwiftUI

struct EyeView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> EyeNSView {
        let v = EyeNSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: EyeNSView, context: Context) {
        nsView.layer?.contents = image   // direct layer update — no SwiftUI diffing per frame
    }
}

final class EyeNSView: NSView {}
```

- [ ] **Step 3: Write `Sources/XRealMirrorApp/ContentView.swift`**

Layout (text sketch — match it):

```
+---------------------------------------------------------------+
|  LEFT · 0x20                        |  RIGHT · 0x21             |
|  (EyeView, 480x640 aspect, black)   |  (EyeView)                |
+---------------------------------------------------------------+
| ● Running · 29.7 pairs/s                          [ Retry ]   |
+---------------------------------------------------------------+
```

```swift
import SwiftUI
import XRealVision

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                EyeView(image: model.latestFrame?.left.image)
                    .overlay(alignment: .topLeading) { paneLabel("LEFT · 0x20") }
                EyeView(image: model.latestFrame?.right.image)
                    .overlay(alignment: .topLeading) { paneLabel("RIGHT · 0x21") }
            }
            .overlay { if model.latestFrame == nil && model.status == .running { Text("Waiting for frames…").foregroundStyle(.secondary) } }

            Divider()
            HStack {
                statusDot(model.status)
                Text(statusText(model.status))
                Spacer()
                if model.status == .running { Text(String(format: "%.1f pairs/s", model.pairsPerSecond)) }
                if model.status == .missing("") { /* unreachable; placeholder for exhaustiveness */ }
                Button("Retry") { model.start() }.keyboardShortcut("r")
            }
            .padding(8)
        }
        .frame(minWidth: 960, minHeight: 420)
        .overlay { missingOverlay(model.status) }
        .onAppear { model.start() }
    }

    private func paneLabel(_ s: String) -> some View {
        Text(s).font(.caption.monospaced().bold()).padding(6)
            .background(.black.opacity(0.6)).foregroundStyle(.white)
    }

    private func statusDot(_ s: AppModel.Status) -> some View {
        Circle().fill(s == .running ? Color.green : (s == .searching ? Color.yellow : Color.red)).frame(width: 8, height: 8)
    }

    private func statusText(_ s: AppModel.Status) -> String {
        switch s {
        case .searching: return "Looking for XREAL Air 2 Ultra…"
        case .running: return "Running"
        case .missing(let reason): return reason
        case .permissionDenied: return "Camera permission denied — enable it in System Settings → Privacy & Security → Camera."
        }
    }

    @ViewBuilder private func missingOverlay(_ s: AppModel.Status) -> some View {
        if case .missing = s {
            VStack(spacing: 12) {
                Image(systemName: "globe.badge.chevron.backward").font(.largeTitle)
                Text("XREAL Air 2 Ultra not found").font(.title2.bold())
                Text(statusText(s)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { model.start() }.buttonStyle(.borderedProminent)
            }
            .padding(40).frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}
```

Notes for the implementer: the `if model.status == .missing("")` line is there only to prove exhaustiveness of the switch — write `statusText` as a clean `switch` over all four cases instead and drop that line; do not pattern-match `.missing` with a literal anywhere else.

- [ ] **Step 4: Write `Sources/XRealMirrorApp/XRealMirrorApp.swift`** and delete `Sources/XRealMirrorApp/main.swift`

```swift
import AppKit
import SwiftUI

@main
struct XRealMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("XRealMirror") {
            ContentView(model: appDelegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular makes the window appear and activate even when run unbundled (`swift run`)
        // during development; harmless when bundled.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 5: Build and launch**

Run: `swift build` then `swift run XRealMirrorApp`
Expected: builds green; a titled `XRealMirror` window opens, shows both panes and, with glasses plugged and permission granted, live feed within ~2 seconds (first frames are skipped, then brightness settles over ~25 frames). With glasses unplugged, the missing overlay appears instead of a crash. Kill with Ctrl-C.

- [ ] **Step 6: Commit**

```bash
git rm -q Sources/XRealMirrorApp/main.swift
git add Sources/XRealMirrorApp/
git commit -m "feat: XRealMirror app — dual live camera panes with permission and device-state handling

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: App bundle + Info.plist + verification script

**Files:**
- Create: `Resources/Info.plist`, `scripts/bundle-app.sh`, `scripts/check-bundle.sh`

**Interfaces:**
- Consumes: the built `XRealMirrorApp` and `XRealProbe` binaries (probe lands in Task 7 — the script already copies it; until then the copy step fails loudly, which is correct).
- Produces: `dist/XRealMirror.app` (gitignored), `scripts/check-bundle.sh`.

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>XRealMirror</string>
    <key>CFBundleIdentifier</key><string>com.immersetebay.xrealmirror</string>
    <key>CFBundleName</key><string>XRealMirror</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>XRealMirror shows the XREAL Air 2 Ultra tracking camera feeds.</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `scripts/bundle-app.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/XRealMirror.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/XRealMirrorApp "$APP/Contents/MacOS/XRealMirror"
cp .build/release/XRealProbe   "$APP/Contents/MacOS/XRealProbe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
```

Note: the probe ships inside the bundle on purpose — macOS keys camera permission to the signed bundle, so the probe inherits the app's TCC grant (spec §Constraints).

- [ ] **Step 3: Write `scripts/check-bundle.sh`** — every gate fails loudly (a delivery gate that can silently pass is the bug — it must exit non-zero with a `FAIL:` line):

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle-app.sh
APP=dist/XRealMirror.app
[ -d "$APP" ] || { echo "FAIL: $APP missing"; exit 1; }
USAGE=$(plutil -extract NSCameraUsageDescription raw "$APP/Contents/Info.plist")
[ -n "$USAGE" ] || { echo "FAIL: NSCameraUsageDescription missing from Info.plist"; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc" || { echo "FAIL: ad-hoc signature missing"; exit 1; }
"$APP/Contents/MacOS/XRealProbe" --devices | grep -q '^XREAL PROBE' || { echo "FAIL: probe smoke failed"; exit 1; }
echo "BUNDLE CHECK PASS"
```

- [ ] **Step 4: Run it (expected to fail until Task 7 exists)**

Run: `./scripts/check-bundle.sh`
Expected: the script fails at the probe smoke step with `FAIL: probe smoke failed` — the placeholder probe prints `XRealProbe placeholder`, which does not carry the `XREAL PROBE` banner, so the gate proves it can catch a placeholder/stale probe. (After Task 7, it must pass end-to-end.) Do not weaken `set -e` or add fallbacks to make it pass.

- [ ] **Step 5: Commit**

```bash
git add Resources/Info.plist scripts/
git commit -m "feat: app bundle assembly, Info.plist with camera usage string, and loud bundle gate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: XRealProbe — live hardware verification CLI

**Files:**
- Create: `Sources/XRealProbe/main.swift` (replaces the placeholder of the same name)

**Interfaces:**
- Consumes: `StereoCamera` (both `delegate` and `rawFrameHandler`), `StereoFrame`, `DecodedFrame`, `CameraID`, `FrameLayout`, `XRealFrameDecoder.makeEyeImage`, `XRealCameraError`.
- Produces: the bundled probe; sample PNGs in `--out` (default `/tmp/xreal-probe`).

Behavior (exactly this contract):

1. `--devices`: print the `XREAL PROBE` banner line first, then list every `.external` video device (name, modelID, `activeFormat` description), then exit 0. No capture, no permission needed. The banner doubles as the bundle gate's content marker — keep it exactly `XREAL PROBE`.
2. Default run: find the XREAL; if absent print `NO XREAL FOUND` and exit 1. Otherwise start `StereoCamera`, set `rawFrameHandler` and `delegate`, capture `--frames` frames (default 40, includes the 6 skipped internally — the probe sees post-skip frames only), then stop.
3. Per decoded frame (via `rawFrameHandler`): track — total frames, per-camera-ID counts, sequence deltas between consecutive frames of the same camera ID (report how many deltas equal 256), and the zero-byte fraction of the first 3 decoded frames (informational: warmup had all-zero frames upstream of the skip).
4. Per stereo pair (via `delegate`): save the first 3 pairs as PNGs to the output directory as `left_0.png`, `right_0.png`, `left_1.png`, … using `makeEyeImage` and this snippet:

```swift
func savePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}
```

5. Print a verdict block:

```
XREAL PROBE
  device: <name> (<modelID>)
  frames decoded: 34 / 34 received (all 308,480 bytes)
  cameras seen: 0x20 x17, 0x21 x17
  sequence deltas == 256: 32/32 same-ID pairs
  first-frame zero fraction: 0.00
  PNGs: /tmp/xreal-probe/left_0.png … (3 pairs)
PROBE PASS
```

or `PROBE FAIL: <reason list>` with exit 1 when: zero frames decoded, frame size ever ≠ 308,480, either camera ID never seen, or the 256-delta rule fails on more than the first delta (the first delta after the skip is allowed to be anything; wrap-around at 0xFFFF→0x0000 counts as a delta of 256 too: `(next &- prev) & 0xFFFF == 256`).

Implementation notes: arguments via `CommandLine.arguments` (no dependencies); the camera delegate delivers on the capture queue — the probe's handler must be thread-safe (confine its state to the capture queue; print the verdict after `stop()`); `FileManager.default.createDirectory(atPath:withIntermediateDirectories:)` for the output dir; `exit(0)`/`exit(1)` explicitly at the end.

- [ ] **Step 1: Build and run `--devices` from the bundle**

Run: `./scripts/check-bundle.sh` then `dist/XRealMirror.app/Contents/MacOS/XRealProbe --devices`
Expected: bundle check PASSes (Task 6's gate, now end-to-end); the device list prints; exit code 0. It should list the XREAL as `UVC Camera VendorID_13080 ProductID_1062` if the glasses are plugged in.

- [ ] **Step 2: Run the full probe against the plugged-in glasses**

Run: `dist/XRealMirror.app/Contents/MacOS/XRealProbe` (from the bundled path — never `swift run`)
Expected: `PROBE PASS`; PNGs written to `/tmp/xreal-probe/`. If the glasses are not plugged in at this moment, `NO XREAL FOUND` + exit 1 is also a correct run — report which one you got.

- [ ] **Step 3: Commit**

```bash
git add Sources/XRealProbe/
git commit -m "feat: XRealProbe — live hardware verification of the raw frame pipeline

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: README + CLAUDE.md

**Files:**
- Create: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write `README.md`** covering, in order: what the app is (mirrors both XREAL Air 2 Ultra tracking cameras, nothing else); requirements (XREAL Air 2 Ultra over USB-C, macOS 15+); build & run (`./scripts/bundle-app.sh` → `open dist/XRealMirror.app`); first-run camera permission (System Settings → Privacy & Security → Camera → enable XRealMirror; re-trigger via the app's Retry); the probe (bundled path command, example output, PNGs at `/tmp/xreal-probe/`); troubleshooting (first seconds dark = sensor warmup ~25 frames; brightness settles; `NO XREAL FOUND` → check cable / System Report → USB; permission reset via `tccutil reset Camera com.immersetebay.xrealmirror`).

- [ ] **Step 2: Write `CLAUDE.md`** for future agents, covering: project purpose and layout (library / app / probe / scripts); lane ownership rule; the three commands (`swift test`, `./scripts/bundle-app.sh`, bundled probe path); hazards verbatim from the spec (never set `videoSettings`; camera ID at `+0x3A` not `+0x3B`; transpose ≠ rotation; skip first 6 frames; probe must run from the bundle for TCC; the dead-ends list — do not retry them).

- [ ] **Step 3: Final whole-lane verification**

Run: `./scripts/check-bundle.sh` (bundle gate), then `swift run XRealMirrorApp` launches with window (glasses unplugged → missing overlay is the expected correct result)
Expected: bundle check PASS; app runs without crash either way.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: README and CLAUDE.md for XRealMirror

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Lane completion

When all four tasks are committed, report: tasks completed; the probe verdict text (exact `PROBE PASS`/`PROBE FAIL`/`NO XREAL FOUND` you observed, from the bundled path); the PNG paths if any; and any deviations from this plan or the spec (each is a report, not a license).
