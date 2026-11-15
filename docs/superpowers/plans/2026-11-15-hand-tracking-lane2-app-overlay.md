# Hand Tracking — Lane 2 (App & Overlay) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The XRealMirror app gains a hand-skeleton overlay: 21 dots + 21 connection segments per hand, one
color per hand, drawn over each eye pane at 30fps, 1€-smoothed, letterbox-correct — while the stage-1 mirror
(60fps display, reconnect, TCC flow) stays exactly as it is.

**Architecture:** Pure geometry (aspect-fit mapping + skeleton point/line layout) and a pure 1€ filter,
fully unit-tested (Tasks 1–2); a thin `HandOverlayNSView` that owns two CAShapeLayers and the smoothing banks,
wired into the existing `EyeView`/`AppModel` (Task 3); live verification on the glasses (Task 4). Lane 1's
`StereoHandTracker` is consumed through the frozen contract only — `accept(_:)` on main (inside the existing
main-actor hop), results back through `StereoHandTrackerDelegate`.

**Tech Stack:** Swift 6.3 (language mode 6), SwiftPM, XCTest, SwiftUI/AppKit (CAShapeLayer), CoreGraphics.

**Spec:** `docs/superpowers/specs/2026-11-15-hand-tracking-design.md` — the interface contract and hazards in
it are authoritative. Read it first. (The superseded stereo doc is history, not authority.)

## Global Constraints

- Code against the spec's Interface contract exactly — `StereoHandTracker.accept`, `StereoHandTrackerDelegate`,
  `StereoHands`/`EyeHands`/`TrackedHand` are what Lane 1 compiles; do not rename or re-signature anything
  without stopping and reporting.
- TDD strictly: for every behavior, write the failing test, watch it fail, then implement. No implementation
  without a red test first.
- Own only `Sources/XRealMirrorApp/**`, `Tests/XRealMirrorAppTests/**` (target already added by the
  coordinator), `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md`. Never touch
  Lane 1's paths (`Sources/XRealVision/**`, `Tests/XRealVisionTests/**`) or `Package.swift` / `.gitignore`.
  If a change seems to need another lane, stop and report.
- The mirror is sacred: the capture→display path (`EyeNSView.layer.contents`, the pairs/s counter, reconnect
  timers) must stay untouched in behavior. The only addition to the frame path is one `accept(_:)` call inside
  the existing main-actor hop — it is non-blocking by contract (Lane 1 pins it with a test).
- Never commit a tree that does not build: every task's final verification is `swift build` green plus
  `swift test` green (the whole package — Lane 1's tests run too). Lane 1 builds the whole package at any time.
- Bundle gate: `./scripts/bundle-app.sh` then `./scripts/check-bundle.sh` must print `BUNDLE CHECK PASS`
  before any task is called done (it protects the TCC/permission behavior the demo depends on).
- Work on `main` in the shared working tree; commit per task; if `git` reports `index.lock`, wait and retry.
  End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

These are the five ways this lane most plausibly ships a wrong overlay; each has a pinned test or check below.

1. Skeleton floating off the hand — landmarks drawn over the pane without the aspect-fit mapping (the image is
   letterboxed by `.resizeAspect`) → `testAspectFitPortraitInWidePane` + `testBuilderMapsPointIntoRect`
   (Task 1).
2. Skeleton upside down or mirrored — contract points fed straight to layers (contract is top-left; any
   re-flip breaks it) → `testBuilderCornerMapping` (Task 1).
3. Jittery skeleton — smoothing state reset per frame (filters keyed wrong) → `testConstantInputConverges` +
   `testStepSettlesWithinHalfSecond` (Task 2).
4. Overlay drift vs the pane — overlay frame not pinned to `EyeNSView` bounds on resize → autoresizing wiring
   step (Task 3) + live check (Task 4).
5. Mirror regression — the new `accept` call or overlay updates stalling the 60fps display path → build + live
   pairs/s check (Task 4); the wiring step (Task 3) puts `accept` inside the existing hop only.

## File Map

- Create: `Sources/XRealMirrorApp/SkeletonGeometry.swift`, `Sources/XRealMirrorApp/OneEuroFilter.swift`,
  `Sources/XRealMirrorApp/HandOverlayNSView.swift`
- Modify: `Sources/XRealMirrorApp/EyeView.swift`, `Sources/XRealMirrorApp/ContentView.swift`,
  `Sources/XRealMirrorApp/AppModel.swift`, `CLAUDE.md` (lane table row)
- Test: `Tests/XRealMirrorAppTests/SkeletonGeometryTests.swift`, `Tests/XRealMirrorAppTests/OneEuroFilterTests.swift`

---

### Task 1: Aspect-fit mapping + skeleton geometry (pure)

**Files:**
- Create: `Sources/XRealMirrorApp/SkeletonGeometry.swift`
- Delete: `Tests/XRealMirrorAppTests/Lane2PlaceholderTests.swift` (the coordinator's placeholder for the new
  target — same pattern as stage 1's `Lane1Placeholder.swift`)
- Modify: `CLAUDE.md` (lane table)
- Test: `Tests/XRealMirrorAppTests/SkeletonGeometryTests.swift`

**Interfaces:**
- Consumes: `TrackedHand`, `HandSkeleton` (Lane 1), `FrameLayout` (stage 1).
- Produces (Task 3 renders these): `AspectFitRect`, `SkeletonGeometry`, `SkeletonPathBuilder`.

- [ ] **Step 1: Write the failing tests** in `Tests/XRealMirrorAppTests/SkeletonGeometryTests.swift`:

```swift
import XCTest
import CoreGraphics
import simd
@testable import XRealMirrorApp
import XRealVision

final class SkeletonGeometryTests: XCTestCase {
    // The trap: the 480x640 image is letterboxed inside the pane by .resizeAspect — landmarks are
    // normalized to the IMAGE, so every drawing path must go through this mapping.
    func testAspectFitPortraitInWidePane() {
        let r = AspectFitRect.fit(imageWidth: 480, imageHeight: 640,
                                  in: CGRect(x: 0, y: 0, width: 1000, height: 400))
        // height-bound: scale = 400/640 = 0.625 → 300x400, centered horizontally
        XCTAssertEqual(r.width, 300, accuracy: 0.001)
        XCTAssertEqual(r.height, 400, accuracy: 0.001)
        XCTAssertEqual(r.midX, 500, accuracy: 0.001)
        XCTAssertEqual(r.midY, 200, accuracy: 0.001)
    }

    func testAspectFitLandscapeInWidePane() {
        let r = AspectFitRect.fit(imageWidth: 640, imageHeight: 480,
                                  in: CGRect(x: 0, y: 0, width: 1000, height: 400))
        // width-bound: scale = 400/480 = 0.8333 → 533.33x400, centered
        XCTAssertEqual(r.width, 1000 * 0.8 / 1.5, accuracy: 0.01)
        XCTAssertEqual(r.height, 400, accuracy: 0.001)
        XCTAssertEqual(r.midX, 500, accuracy: 0.001)
    }

    func testAspectFitExactMatchAndOffsetContainer() {
        XCTAssertEqual(AspectFitRect.fit(imageWidth: 100, imageHeight: 200,
                                         in: CGRect(x: 0, y: 0, width: 100, height: 200)),
                       CGRect(x: 0, y: 0, width: 100, height: 200))
        // 100x100 image in a 200x300 container: width-bound (scale 2) → 200x200, centered → x = 10, y = 70
        let r = AspectFitRect.fit(imageWidth: 100, imageHeight: 100,
                                  in: CGRect(x: 10, y: 20, width: 200, height: 300))
        XCTAssertEqual(r, CGRect(x: 10, y: 70, width: 200, height: 200))
    }

    func testAspectFitDegenerateContainer() {
        XCTAssertEqual(AspectFitRect.fit(imageWidth: 480, imageHeight: 640, in: .zero), .zero)
    }

    private func hand(_ pts: [SIMD2<Float>]) -> TrackedHand {
        TrackedHand(landmarks: pts, confidences: [Float](repeating: 1, count: pts.count), chirality: .right)
    }

    // Contract points are normalized top-left; geometry maps them into the image rect.
    func testBuilderMapsPointIntoRect() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        pts[0] = SIMD2<Float>(0.5, 0.5)          // wrist at image center
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(geo.dots.count, 21)
        XCTAssertEqual(geo.lines.count, 21)      // HandSkeleton.connections, all 21
        XCTAssertEqual(geo.dots[0], CGPoint(x: 60, y: 120))
    }

    func testBuilderCornerMapping() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        pts[0] = SIMD2<Float>(0, 0)              // top-left of the image
        pts[1] = SIMD2<Float>(1, 1)              // bottom-right
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(geo.dots[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(geo.dots[1], CGPoint(x: 110, y: 220))
    }

    func testBuilderLineEndpointsAreMappedDots() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        for i in 0..<21 { pts[i] = SIMD2<Float>(Float(i % 7) / 7, Float(i % 5) / 5) }
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 0, y: 0, width: 700, height: 500))
        for (line, conn) in zip(geo.lines, HandSkeleton.connections) {
            XCTAssertEqual(line.0, geo.dots[conn.from])
            XCTAssertEqual(line.1, geo.dots[conn.to])
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SkeletonGeometryTests`
Expected: compile failure (`AspectFitRect` etc. undefined).

- [ ] **Step 3: Implement in `Sources/XRealMirrorApp/SkeletonGeometry.swift`**

```swift
enum AspectFitRect {
    static func fit(imageWidth: Int, imageHeight: Int, in container: CGRect) -> CGRect
    // scale = min(cw/iw, ch/ih); centered in the container. Zero image size or container → .zero.
}

struct SkeletonGeometry: Equatable {
    var dots: [CGPoint]                 // 21, image-rect space, canonical HandJoint order
    var lines: [(CGPoint, CGPoint)]     // 21, HandSkeleton.connections order
}

enum SkeletonPathBuilder {
    static func geometry(hand: TrackedHand, in rect: CGRect) -> SkeletonGeometry
    // dots[i] = CGPoint(rect.minX + x * rect.width, rect.minY + y * rect.height) for landmarks[i].
    // Draw ALL points (confidences are carried for future use; v1 does not filter). Lines connect the
    // mapped dots via HandSkeleton.connections — exactly 21, in the constant's order.
}
```

- [ ] **Step 4: Update `CLAUDE.md`** — the lane table is this lane's file. Add `Tests/XRealMirrorAppTests/**`
  to the Person 2 row so the table matches the spec ("spec supersedes the table for new paths" — now the table
  agrees with it, no superseding left to read). Also delete
  `Tests/XRealMirrorAppTests/Lane2PlaceholderTests.swift` (its job is done — the real tests land in Step 1).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SkeletonGeometryTests` then `swift build`
Expected: all pass, build green. (Do not assert a total test count — the suite is shared and grows.)

- [ ] **Step 6: Commit**

```bash
git add Sources/XRealMirrorApp/SkeletonGeometry.swift Tests/XRealMirrorAppTests/SkeletonGeometryTests.swift CLAUDE.md
git rm -q Tests/XRealMirrorAppTests/Lane2PlaceholderTests.swift
git commit -m "feat: aspect-fit image mapping and hand skeleton geometry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: One-euro smoothing filter (pure)

**Files:**
- Create: `Sources/XRealMirrorApp/OneEuroFilter.swift`
- Test: `Tests/XRealMirrorAppTests/OneEuroFilterTests.swift`

**Interfaces:**
- Produces (Task 3 smooths with it): `OneEuroFilter`.

- [ ] **Step 1: Write the failing tests** in `Tests/XRealMirrorAppTests/OneEuroFilterTests.swift`:

```swift
import XCTest
@testable import XRealMirrorApp
import simd

final class OneEuroFilterTests: XCTestCase {
    // Pinned defaults from the spec's smoothing character: smooth but not floaty.
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(SIMD2<Float>(0.3, 0.7), timestamp: 0.0), SIMD2<Float>(0.3, 0.7))
    }

    func testConstantInputConverges() {
        var f = OneEuroFilter()
        let target = SIMD2<Float>(0.42, 0.58)
        var out = f.filter(target, timestamp: 0.0)
        for i in 1...90 { out = f.filter(target, timestamp: Double(i) / 30.0) }   // 3 s at 30fps
        XCTAssertLessThan(simd_distance(out, target), 0.01)
    }

    func testStepSettlesWithinHalfSecond() {
        var f = OneEuroFilter()
        var out = f.filter(.zero, timestamp: 0.0)
        for i in 1...60 { out = f.filter(.zero, timestamp: Double(i) / 30.0) }    // settle at 0
        out = f.filter(SIMD2<Float>(1, 1), timestamp: 61.0 / 30.0)
        for i in 62...76 { out = f.filter(SIMD2<Float>(1, 1), timestamp: Double(i) / 30.0) }
        XCTAssertGreaterThan(out.x, 0.9)   // a half second after the step, ~90% of the way there
        XCTAssertGreaterThan(out.y, 0.9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OneEuroFilterTests`
Expected: compile failure (`OneEuroFilter` undefined).

- [ ] **Step 3: Implement in `Sources/XRealMirrorApp/OneEuroFilter.swift`**

```swift
struct OneEuroFilter {
    init(minCutoff: Double = 1.0, beta: Double = 0.05, derivativeCutoff: Double = 1.0)
    mutating func filter(_ value: SIMD2<Float>, timestamp: TimeInterval) -> SIMD2<Float>
    // Standard 1€ (Casiez et al.): per-component low-pass on the value, cutoff raised by |dx/dt|·beta,
    // derivative itself low-passed at derivativeCutoff. Timestamps are monotonic seconds; the first
    // sample initializes state and passes through untouched.
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OneEuroFilterTests` then `swift build`
Expected: all pass, build green. If `testStepSettlesWithinHalfSecond` fails, tune `beta` up or `minCutoff` up
and re-run — the character bar is "half a second to ~90% on a step", not the exact constants (note any change
in the commit message).

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealMirrorApp/OneEuroFilter.swift Tests/XRealMirrorAppTests/OneEuroFilterTests.swift
git commit -m "feat: one-euro smoothing filter for overlay landmarks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Overlay view + AppModel/ContentView wiring

**Files:**
- Create: `Sources/XRealMirrorApp/HandOverlayNSView.swift`
- Modify: `Sources/XRealMirrorApp/EyeView.swift`, `Sources/XRealMirrorApp/ContentView.swift`,
  `Sources/XRealMirrorApp/AppModel.swift`

**Interfaces:**
- Consumes: `EyeHands`, `StereoHands`, `StereoHandTracker`, `StereoHandTrackerDelegate`, `VisionHandDetector`
  (all Lane 1), `FrameLayout`, plus Tasks 1–2 of this lane.
- Produces: `HandOverlayNSView` (app-internal; nothing crosses lanes).

- [ ] **Step 1: Implement `HandOverlayNSView`** in `Sources/XRealMirrorApp/HandOverlayNSView.swift`

```swift
final class HandOverlayNSView: NSView {
    func update(hands: EyeHands?)
}
```

Approach (no new tests — the pure math this view consumes is already pinned in Tasks 1–2; this is the thin
render layer):
- `wantsLayer = true`; two `CAShapeLayer` sublayers — `dotsLayer` and `linesLayer` — added in `init`, frames
  pinned to `bounds` (use `NSView.frameDidChangeNotification` or override `layout` to keep them matched).
- `update(hands:)`: nil or empty → set both layers' `path = nil` and return (the plain stage-1 mirror shows
  through). Otherwise, for each `TrackedHand` in `hands.hands`:
  - Smoothing bank per hand, keyed by `chirality` (one `OneEuroFilter` per joint, 21 per bank). If the set of
    chiralities present changed since last update, rebuild the banks (hands are unordered frame to frame).
    Filter timestamp = `CACurrentMediaTime()`.
  - `SkeletonPathBuilder.geometry(hand: filtered, in: AspectFitRect.fit(imageWidth: FrameLayout.uprightWidth,
    imageHeight: FrameLayout.uprightHeight, in: bounds))` — the letterbox mapping, pinned by Task 1.
  - Dot: `CGPath(ellipseIn:)` of radius 3pt per point, merged into one `CGPath` per hand. Line: move/line
    segments per `SkeletonGeometry.lines`. Colors: `.left` → `NSColor.systemCyan`, `.right` →
    `NSColor.systemOrange`, `.unknown` → `NSColor.systemYellow` (one color per hand, applied via the layer
    stroke/fill when possible, else per-path `CGPath` copy with `CGColor`).
- All drawing state lives on the main actor; `update` is called from `updateNSView` (main).

- [ ] **Step 2: Wire `EyeView.swift`** — `EyeView` gains `let hands: EyeHands?` (default nil). In
  `makeNSView`, after the existing setup, add a `HandOverlayNSView` as a subview of `EyeNSView` with
  `frame = v.bounds` and `autoresizingMask = [.width, .height]` (overlay is always exactly the pane — the
  aspect-fit mapping inside handles the letterboxing). In `updateNSView`, keep
  `nsView.layer?.contents = image` exactly as-is, and call `nsView.handOverlay.update(hands: hands)`.

- [ ] **Step 3: Wire `AppModel.swift`**

  - Add `@Published var latestHands: StereoHands?` next to `latestFrame`.
  - Add `private var handTracker: StereoHandTracker?`.
  - In `beginCapture()`, after the camera starts: `let tracker = StereoHandTracker(); tracker.delegate = self;
    handTracker = tracker` (a fresh tracker per capture attempt, same lifecycle as the camera). In `stop()`:
    `handTracker?.delegate = nil; handTracker = nil`.
  - In the existing `stereoCamera(_:didEmit:)` — inside the `Task { @MainActor in ... }` body, after
    `self.pairCounter += 1`: `self.handTracker?.accept(box.frame)`. That is the ONLY change to the frame path:
    one non-blocking enqueue on main. Do not touch `latestFrame`, the counter, or the identity guard.
  - Add:

```swift
extension AppModel: StereoHandTrackerDelegate {
    // Called on the tracker's queue — hop to main, drop results from a tracker we've already replaced.
    nonisolated func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands) {
        let source = ObjectIdentifier(tracker)
        Task { @MainActor in
            guard let current = self.handTracker, ObjectIdentifier(current) == source else { return }
            self.latestHands = hands
        }
    }
}
```

- [ ] **Step 4: Wire `ContentView.swift`** — both `EyeView(...)` calls gain the hands argument:
  `EyeView(image: model.latestFrame?.left.image, hands: model.latestHands?.leftEye)` and the same for right.
  Note: `latestHands` can lag `latestFrame` by up to one tracker cycle (~33ms) — intentional (the overlay
  updates at 30fps, the mirror at 60), documented in the spec, invisible in practice.

- [ ] **Step 5: Verify the whole package**

Run: `swift test` then `swift build -c release`
Expected: all tests pass (Lane 1's included), both builds green.

- [ ] **Step 6: Commit**

```bash
git add Sources/XRealMirrorApp/HandOverlayNSView.swift Sources/XRealMirrorApp/EyeView.swift \
        Sources/XRealMirrorApp/ContentView.swift Sources/XRealMirrorApp/AppModel.swift
git commit -m "feat: hand skeleton overlay wired through EyeView and AppModel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Bundle gate + live verification on the glasses

**Files:** none expected (tuning fixes only, if any).

**Interfaces:**
- Consumes: everything from Tasks 1–3; `scripts/bundle-app.sh`, `scripts/check-bundle.sh`.

- [ ] **Step 1: Bundle and gate**

Run: `./scripts/bundle-app.sh` then `./scripts/check-bundle.sh`
Expected: `BUNDLE CHECK PASS`. If not, stop and report — the demo's TCC behavior depends on the bundle.

- [ ] **Step 2: Live checklist** (glasses in camera mode, run
  `dist/XRealMirror.app/Contents/MacOS/XRealMirror` — never `swift run` for the real camera):

  - [ ] Mirror unchanged: both panes live, pairs/s ≈ 60 (watch the status bar — the stage-1 watchdog).
  - [ ] Hands in view → skeletons follow both hands in BOTH panes, one color per hand, updating ~30fps
        (watch for one-frame cadence, not 60fps flicker).
  - [ ] Skeleton sits ON the hand, not beside it (letterbox mapping) and not upside down (contract y-flip).
  - [ ] Slow hand movement → smooth tracking, no overshoot; fast movement → skeleton keeps up within ~0.5s
        (the 1€ character bar from Task 2).
  - [ ] Hands out of view → overlay disappears, mirror stays live; hands return → overlay resumes.
  - [ ] No camera-permission prompt on relaunch (bundle gate + stage-1 grant still hold).

- [ ] **Step 3: Commit any tuning**

If the live run forced a change (filter constants, dot radius, colors): commit it with a message naming the
observed problem:

```bash
git add <changed files>
git commit -m "fix(overlay): <what was wrong on the glasses, e.g. skeleton lagged on fast chords>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Lane completion

When all four tasks are done: `swift test` green, `swift build -c release` green, `BUNDLE CHECK PASS`, the live
checklist fully ticked, and report back with: tasks completed, live pairs/s observed with and without the
overlay active, and any deviations from this plan or the spec (each deviation is a report, not a license —
none were needed if all steps passed as written).
