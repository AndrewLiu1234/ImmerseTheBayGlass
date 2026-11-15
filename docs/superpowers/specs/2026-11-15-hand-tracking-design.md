# Hand-Tracking Overlay — Design

Date: 2026-11-15. Stage 2 of XRealMirror. Author: coordinator. Supersedes
`2026-11-15-stereo-neck-tracking-design.md` (stereo fretboard path parked on the user's pivot).

## Intent & why

Stage 1 mirrors both XREAL Air 2 Ultra cameras on the Mac — done, live-verified. Stage 2 puts **hand tracking**
on top: the XRealMirror app gains an overlay that draws a **21-landmark skeleton following each hand** the
player sees through the glasses, one skeleton per eye pane, **updated at 30fps**. The user's priorities, in
order: (1) speed — 30fps is the bar; (2) simplicity — "whatever works, especially if you can build off what
already exists"; (3) optimization. The user's first call was open-source MediaPipe Hands; the follow-up
("whatever works, build off what exists") is what the backend decision below is made under.

## Goals

- **G1 — Hand skeleton overlay.** Up to 2 hands per eye pane, each drawn as 21 landmark dots + 21 connection
  segments, one color per hand, positioned over the hand in the live mirror. Both eyes are tracked
  independently, so each pane's skeleton matches what that pane shows.
- **G2 — 30fps with measured budgets.** The glasses stream 60fps pairs; the tracker processes every other pair
  (30fps). Budgets on this MBP: detection ≤ 15ms per pair (both eyes), overlay render ≤ 5ms per pair, and the
  **mirror display must stay at 60fps** (the stage-1 pairs/s indicator is the watchdog). A benchmark test
  ships in the test suite so a gross regression fails `swift test`; the real budget is verified live.
- **G3 — No hands = plain mirror.** When neither eye sees a hand, the app is exactly the stage-1 mirror — the
  overlay simply draws nothing. Hand tracking must never break stage 1 (permission flow, mirror, reconnect).
- **G4 — Zero third-party dependencies.** Everything new is Swift + system frameworks, fully unit-testable
  without the glasses.

## Non-goals

- No stereo 3D neck/fretboard tracking, no ArUco marker (parked; see the superseded doc).
- No MediaPipe in v1 (kept as a drop-in slot behind the detector seam; see Approaches).
- No fisheye undistortion this stage — landmarks are drawn where the (distorted) hand appears, which is what
  "following the hands you see" means.
- No gesture recognition, no hand-sign interpretation, no z-depth use, no recording, no rendering into the
  glasses. Everything else the Stage 1 spec excludes stays excluded.

## Anti-goals (failures even if it technically works)

- Jittery or laggy skeleton — smoothing must reproduce the stage-1 character: smooth, not floaty.
- Stalling the mirror: detection work must never run on the capture/display path. The tracker's `accept` is
  O(1) enqueue-only.
- A skeleton drawn over the whole pane while the image is letterboxed inside it (the aspect-fit trap — the
  overlay must map landmarks into the image's displayed rect, see Hazards).
- Touching another lane's files (ownership below) or re-signaturing the Stage 1 contract.

## Constraints

- **Lane ownership:** `Sources/XRealVision/**` + `Tests/XRealVisionTests/**` = Person 1 (tracker core).
  `Sources/XRealMirrorApp/**`, `Tests/XRealMirrorAppTests/**` (new target, added by the coordinator),
  `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md` = Person 2 (overlay + app).
  `Package.swift`, `.gitignore`, `docs/**` = coordinator. This spec supersedes the repo CLAUDE.md lane table
  on the one new path (`Tests/XRealMirrorAppTests/**`); Person 2 updates CLAUDE.md while landing their Task 1.
- **Stage 1 contract is frozen:** `XRealFrameDecoder`, `StereoPairer`, `StereoCamera`, `FrameLayout`,
  `StereoFrame` signatures stay as-is; the tracker is a new consumer, the overlay a new view.
- **Swift 6, zero third-party dependencies.** Apple Vision is a system framework (macOS 11+, this repo targets
  macOS 15) — it satisfies the constraint off the shelf. Nothing new enters Package.swift except the
  coordinator-added `XRealMirrorAppTests` target.
- **Hardware realities (verified live, stage 1):** frames arrive 60fps as 480×640 **grayscale** upright
  images; sequence **steps 256 per pair and wraps every 256 pairs** (never use sequence parity for
  decimation); Person 2's auto-reconnect restarts capture on device flap; camera TCC lives with the bundle.
- **Detector input:** frames are converted grayscale→RGB before detection (vImage, ~0.1ms at this size). Vision
  is documented for color input; the conversion is cheap insurance that also keeps the MediaPipe slot honest
  (MediaPipe requires RGB).

## Approaches considered

1. **Backend: MediaPipe Hands vs Apple Vision.** MediaPipe was the user's first call: mature, open source, the
   canonical 21-landmark hand tracker. But its official Swift API is iOS-only; on macOS it means a Bazel source
   build or a community XCFramework — both violate this repo's zero-dependency constraint and add a build
   system to babysit. Apple Vision's `VNDetectHumanHandPoseRequest` is the same 21-landmark topology, built
   into macOS, Swift-native, runs on the ANE (reported ~4–8ms per call on Apple Silicon), and lands directly on
   the stage-1 pipeline — "build off what already exists". Under the user's license ("whatever works"),
   **Vision is chosen**. The `HandDetecting` protocol is the seam: MediaPipe drops in later as one file without
   touching the contract or the app.
2. **Both eyes vs one eye.** Both eyes, independently. Each pane's skeleton must match that pane's own view
   (the hands sit at different screen positions per eye); two Vision calls fit the 15ms budget.
3. **Smoothing location.** Lane 2 (presentation). Lane 1 emits raw per-frame landmarks; the app owns look and
   feel, matching the stage-1 split where the core is honest data and the app decides how it's shown.

## The how (architecture)

```
StereoCamera (Stage 1, frozen)
   └─ StereoPairer ──> StereoFrame (left+right CGImage, 480×640 gray, 60fps)
                          │  AppModel.stereoCamera(_:didEmit:) — existing main-actor hop
                          │  calls tracker.accept(frame) on main (O(1) enqueue)
                          ▼
              StereoHandTracker (Lane 1, new, in Sources/XRealVision)
                 ├─ decimate: every other accepted pair (counter, NOT sequence parity)
                 ├─ latest-wins: at most one pending pair; newer replaces older
                 ├─ gray→RGB (vImage) per eye
                 ├─ HandDetecting.detectHands(in:) per eye   ← the MediaPipe slot
                 │     └─ VisionHandDetector (VNDetectHumanHandPoseRequest, max 2 hands)
                 ├─ HandObservationMapper: Vision 21-joint dict → canonical ordered array
                 │     + y-flip (Vision origin bottom-left → contract top-left)
                 └─ emits StereoHands via StereoHandTrackerDelegate (tracker's queue)
                          │
                          ▼
              App overlay (Lane 2, in Sources/XRealMirrorApp)
                 maps normalized landmarks into each pane's aspect-fit image rect,
                 1€-smooths per joint, draws dots + connections via CAShapeLayers,
                 one color per hand; both eyes empty → draw nothing (plain mirror).
```

**The interface contract (frozen by coordinator; the only cross-lane surface):**

```swift
// Sources/XRealVision
public enum HandChirality: Sendable { case left, right, unknown }

public struct TrackedHand: Sendable {
    public var landmarks: [SIMD2<Float>]   // exactly 21, canonical HandJoint order,
                                           // normalized 0...1, origin TOP-LEFT of the upright image
    public var confidences: [Float]        // exactly 21, same order
    public var chirality: HandChirality
}

public struct EyeHands: Sendable {
    public var hands: [TrackedHand]        // 0...2, unordered
}

public struct StereoHands: Sendable {
    public var leftEye: EyeHands
    public var rightEye: EyeHands
    public var sequence: UInt16            // the source StereoFrame's sequence
    public var timestampMicros: UInt64
}

public protocol HandDetecting {
    func detectHands(in image: CGImage) throws -> [TrackedHand]
    // Called only on the tracker's serial queue. Implementations are stateless besides the Vision request.
}

public protocol StereoHandTrackerDelegate: AnyObject {
    func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands)
}

public final class StereoHandTracker: @unchecked Sendable {
    public init(detector: any HandDetecting = VisionHandDetector(), processEveryNthPair: Int = 2)
    public weak var delegate: StereoHandTrackerDelegate?
    public func accept(_ frame: StereoFrame)   // non-blocking, O(1), callable from any queue; safe from main
}
```

`didTrack` always delivers a non-nil `StereoHands`; empty `hands` arrays mean "no hands in that eye this
frame" — normal, not an error. The overlay draws nothing for empty arrays. (No optional in the callback: two
nil-able layers collapse into one.)

**Speed levers (measured, not assumed):**
- Every-other-pair decimation (60→30fps) — the single biggest lever. Count **accepted pairs**, never sequence
  parity (sequence steps 256 per pair — its parity is constant).
- `accept` is enqueue-only: detection runs on the tracker's own serial queue; the capture/display path is
  untouched, so the mirror keeps 60fps no matter what detection costs.
- Latest-wins: a slow frame is dropped, never queued behind a newer one — latency stays at one frame.
- Gray→RGB via `vImageConvert_Planar8toRGB888`, one call per eye, reused buffers, no per-frame heap churn.
- Overlay: two CAShapeLayers per pane (dots + lines), path rebuilt only on new results (30fps), ≤5ms budget
  is generous for 42 points + 21 segments.

## Hazards (the traps; each has a pinned test, named in the lane plans)

1. **Coordinate origin:** Vision's `recognizedPoints` are normalized with origin **bottom-left**; the contract
   is **top-left** (CALayer geometry). The mapper flips y; forgetting it draws the skeleton upside down.
2. **Joint order:** the contract pins the canonical 21-joint order (wrist first). Vision names them
   (`thumbMP`, not `thumbMCP`; `little*`, not `pinky*`) — a wrong mapping scrambles the skeleton.
3. **Aspect-fit trap:** `EyeNSView.layer.contentsGravity = .resizeAspect` letterboxes the 480×640 image inside
   the pane. Landmarks are normalized to the **image**; drawing them over the pane must go through the same
   aspect-fit mapping or the skeleton floats off the hand.
4. **Decimation by sequence parity:** sequence steps 256 per pair (stage-1 hazard) — parity is constant, so
   parity-based decimation either never fires or fires every frame. Count pairs instead.
5. **Tracker on the capture path:** `accept` must not run detection. The non-blocking property is tested with
   a blocked fake detector.

## Verification

- `swift test` green: Lane 1 pins contract constants, y-flip, joint mapping, decimation, latest-wins,
  non-blocking `accept`, and a detector smoke budget; Lane 2 pins aspect-fit math, skeleton geometry, and the
  1€ filter — all without the glasses.
- Benchmark test (Lane 1): times `VisionHandDetector` on 480×640 frames and prints a report; asserts only a
  loose smoke bound (median < 100ms) so CI stays honest while the real 15ms budget is verified live.
- Live (Lane 2 Task 4): bundled app + glasses — skeletons follow both hands in both panes at 30fps, pairs/s
  stays ~60, hands out of view → plain mirror, no TCC regression.

## Reconciliation with the Stage 1 spec

`2026-11-14-xrealmirror-design.md` lists hand tracking and overlays as non-goals. **That spec is superseded by
this one on exactly those points** (this stage exists to add them), and it supersedes the stage-2 stereo doc
entirely. Everything else in the Stage 1 spec — the wire format, the rotation/mirror traps, the pairing
contract, the bundle/TCC rules, the hazards — remains binding and unchanged.
