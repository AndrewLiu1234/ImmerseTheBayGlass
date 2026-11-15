# Stereo Guitar-Neck Tracking — Design

> **SUPERSEDED 2026-11-15** by `2026-11-15-hand-tracking-design.md` — user pivoted: hand tracking first
> ("whatever works, build off what already exists"). The stereo fretboard path and its feasibility critique
> stay here as the historical record of the decision.

Date: 2026-11-15. Stage 2 of XRealMirror. Author: coordinator.

## Intent & why

Stage 1 mirrors both XREAL Air 2 Ultra cameras on the Mac — done, live-verified. Stage 2 processes that
live footage: track the neck of a guitar in **3D** from the **stereo** view and visualize it as an overlay on
the computer screen, **live at 30fps**. The user's priorities, in order: (1) speed — real-time tracking at a
high frame rate; (2) simplicity — "keep it as simple as possible, we just want something that works";
(3) optimization. This builds directly on the validated Guitar Vision MVP (ArUco marker anchoring), porting
its math into the XRealMirror pipeline and lifting it from 2D to stereo 3D.

## Goals

- **G1 — 3D neck pose per frame.** A tracker core consumes the paired stereo frames Stage 1 already emits and
  produces, per processed frame: the neck axis in 3D (endpoints), fret positions 0–12 in 3D, plus the raw marker
  pose and a confidence value, in a glasses-rig coordinate frame (mm).
- **G2 — 30fps with measured budgets.** The glasses stream at 60fps; the tracker processes every other pair
  (30fps). Budgets on this MBP (measured headroom: decode+rotate+CGImage = **0.05 ms/frame**, so ~32ms is free):
  marker detection ≤ 5ms per eye, tracker total ≤ 15ms per frame, overlay render ≤ 5ms. A benchmark target
  ships in the repo and runs in CI/tests so regressions are caught by a number, not by eye.
- **G3 — 3D overlay on the Mac screen.** The app renders the tracked neck (axis line + fret ticks) in 3D over
  the live camera view, locked to the guitar, smoothed (no jitter). When no marker is visible, the app remains
  a plain mirror — the overlay simply isn't drawn.
- **G4 — Reuses the MVP's printed marker and measured math.** One ArUco marker (DICT_4X4_50, id 7, 120mm — the
  print sheet already exists in `guitar-vision-mvp/art/markers/`) clipped at the 14th fret. Neck and frets are
  derived from rigid marker→neck offsets + the scale-length formula, never from visual fret detection:
  Yamaha F600 `scaleM = 0.634 m`, nut ≈ (52, −352) mm from the marker origin, side offset ≈ 52 mm,
  fret n at `scaleM·(1 − 2^(−n/12))`. These constants are ported verbatim from
  `guitar-vision-mvp/tools/camera-vision/camera_bridge.py` — never re-derived.

## Non-goals

- **No recorder** (the user cut it — "keep it simple"; live pipeline only).
- **No fret-number recognition** — fret positions are scale-length math anchored to the marker, not image features.
- **No markerless neck detection** in this stage (a detector interface keeps a slot for it later; see Approaches).
- **No rendering into the glasses** — the overlay lives on the Mac screen. The glasses stay a pure camera
  (clear lenses, no display mode).
- Everything else excluded by the Stage 1 spec stays excluded (hand tracking, audio, webcam fallback, recording UI…).

## Anti-goals (failures even if it technically works)

- Jittery or floating overlay — the MVP's praised smoothness came from raw corner tracking; the 3D path must
  keep that character.
- Dropping below 30fps, or letting the tracker stall the mirror (frame delivery must stay decoupled from tracking).
- Breaking Stage 1: the mirror app must keep working with the marker absent.
- Touching another lane's files (lane ownership below) or re-signaturing the Stage 1 interface contract.

## Constraints

- **Lane ownership (repo CLAUDE.md):** `Sources/XRealVision/**` and `Tests/**` = Person 1 (tracker core lands
  there). `Sources/XRealMirrorApp/**` = Person 2 (overlay lands there). `Package.swift`, `.gitignore`,
  `docs/**` = coordinator. The new interface contract (below) is the only cross-lane surface; nobody edits the
  other lane's files.
- **Stage 1 contract is frozen:** `XRealFrameDecoder`, `StereoPairer`, `StereoCamera` signatures stay as-is;
  the tracker is a new consumer.
- **Swift 6, zero third-party dependencies.** The ArUco detector is hand-ported (see Approaches); nothing new
  enters Package.swift except, if needed, coordinator-added targets for tests.
- **Hardware realities (verified live):** the glasses must stay in camera mode (display mode drops the UVC bus);
  frames arrive 60fps as 480×640 grayscale upright images; Person 2's auto-reconnect already restarts capture
  on device flap. The marker is seen from the **player's POV** (glasses-mounted cameras) — placement/lighting
  assumptions from the MVP's outward-facing webcam must be re-verified, not assumed.
- **Calibration gap (the biggest technical risk).** No camera intrinsics exist in this repo. Stage 1's spec
  mentions a device-side "fisheye624" calibration but nothing usable here. See Approaches / the calibration
  section — the design bootstraps a pinhole approximation and self-calibrates the rig from the marker itself.
- **Machine:** arm64 Mac; Swift toolchain already proven on this repo (build + tests + bundle gate).

## Approaches considered

1. **Marker vs markerless.** ArUco marker — **picked by the user**. It is the MVP's validated, fast, robust
   path; markerless edge detection is slower, lighting-fragile, and left as a future slot behind the same
   `NeckDetector` interface.
2. **2D vs 3D.** 3D stereo — **picked by the user** ("use two eyes view to build a 3D view of the neck").
   2D single-eye was the faster fallback; 3D wins on the user's direction, and the measured headroom
   (32ms/frame free) makes the extra eye essentially free at 30fps.
3. **Recorder lane vs visualization lane.** The user cut the recorder ("keep it simple"); the second lane
   is the 3D overlay visualization instead.
4. **Detection engine** (coordinator's call, stated plainly):
   - *Hand-ported ArUco DICT_4X4_50 detector in Swift/Accelerate — **chosen**.* One dictionary, one marker id,
     known 120mm size: adaptive threshold → quad candidates → perspective warp → 4×4 bit decode → subpixel
     corner refinement. Bounded (~500–800 lines), fully in-lane, dependency-free, and the only option whose
     inner loop we can hand-optimize for the speed priority. Detection budget (≤5ms/eye on 480×640 gray) is
     realistic: the port avoids OpenCV's generality (all dictionaries, all sizes).
   - *OpenCV vendored (brew/XCFramework).* Battle-tested but a heavyweight link-time dependency, license/abi
     friction, and no clean SPM story — rejected for a one-marker problem.
   - *Python cv2 bridge process (MVP's approach).* Rejected: per-frame IPC at 30fps stereo adds latency and a
     second runtime to babysit; the MVP bridged over UDP for Unity, which this stage doesn't need.

## The how (architecture)

```
StereoCamera (Stage 1, frozen)
   └─ StereoPairer ──> StereoFrame (left+right 480×640 gray, 60fps)
                          │  (every other pair: 30fps)
                          ▼
              StereoNeckTracker (Lane 1, new, in Sources/XRealVision)
                 ├─ ArUco4x4Detector: detect marker corners per eye (Accelerate, subpixel)
                 ├─ RigCalibration: per-eye pinhole intrinsics + inter-eye extrinsics
                 │     (bootstrapped once; refined online from both-eyes marker correspondences)
                 ├─ Triangulate: same marker corners in L and R → 3D corners in rig frame
                 ├─ NeckModel: rigid marker→neck offset + scale-length frets (MVP constants)
                 └─ PoseFilter: smoothing (exponential/1€, tuned like the MVP's filter)
                          │
                          ▼
                 NeckPose {neckStart, neckEnd: SIMD3<Float>, frets: [SIMD3<Float>],
                           markerPose, confidence, sequence, timestamp}   ← the contract
                          │
                          ▼
              App overlay (Lane 2, in Sources/XRealMirrorApp)
                 renders neck axis + fret ticks in 3D (SceneKit) over the live view,
                 smoothed, 30fps; absent marker → plain mirror.
```

**The interface contract (frozen by coordinator; the only cross-lane surface):**

```swift
public struct NeckPose {            // in Sources/XRealVision
    public var neckStart: SIMD3<Float>     // nut, rig frame, mm
    public var neckEnd: SIMD3<Float>       // body end of the neck axis, mm
    public var frets: [SIMD3<Float>]       // fret 0...12 positions on the neck axis, mm
    public var markerPose: SIMD3<Float>    // marker origin, mm
    public var confidence: Float           // 0...1
    public var sequence: UInt16            // the source StereoFrame's sequence
    public var timestampMicros: UInt64
}
public protocol StereoNeckTrackerDelegate: AnyObject {
    func stereoNeckTracker(_ tracker: StereoNeckTracker, didTrack pose: NeckPose?)
}
```

`pose == nil` means "no marker this frame" — the overlay fades the last known neck rather than snapping.
Lane 2 consumes only this; Lane 1 implements only this.

**Calibration (Lane 1 owns it, simplest thing that works):**
- Per-eye intrinsics: pinhole approximation. Start from the MVP's 640-normalized `DEFAULT_FX/cx/cy` constants
  rescaled to our 480-wide upright frames; add a one-time checkerboard helper only if the pinhole proves
  insufficient in practice. Do not build full fisheye calibration in v1.
- Rig extrinsics: estimate from the marker itself — the same 120mm marker seen in both eyes yields scale and
  rotation from correspondences; re-estimate lazily each session (a few frames). This keeps v1 free of any
  calibration ceremony.
- Marker placement sensitivity (player POV): the tracker must be robust to the marker being closer/larger
  than in the MVP. Detection works on the full 480×640 image; multi-scale search if needed.

**Speed levers (all in Lane 1; measured, not assumed):**
- Every-other-pair decimation (60→30fps) — the single biggest lever.
- Detection on the full gray frame (480×640 is already small); skip pyramid stages OpenCV needs.
- Accelerate (vImage) for threshold/warp steps; no per-frame heap churn (reused buffers).
- Benchmark harness in the test target: synthetic marker frames (rendered from the known marker bitmap at
  randomized poses) + the real PNG pairs captured in Stage 1 (`/tmp/xreal-probe`-style) with per-stage timers.

## What's left to the builder

- The exact `ArUco4x4Detector` internals (threshold policy, quad filtering, subpixel refinement choice) —
  any correct implementation that meets the detection budget.
- `PoseFilter` specifics (1€ vs exponential smoothing and its constants) — must reproduce the MVP's
  smooth-but-not-laggy character.
- Lane 2's render stack: SceneKit chosen for simplicity; Metal only if 30fps render is missed (it won't be).
- Test fixtures: synthetic marker frames must be *rendered* (perspective-warped marker bitmap), never just
  hand-drawn quads, so the detector is exercised end-to-end.

## Reconciliation with the Stage 1 spec

`2026-11-14-xrealmirror-design.md` lists "3D lifting … overlays" as non-goals. **That spec is superseded by
this one on exactly those two points** (this stage exists to add them). Everything else in the Stage 1 spec —
the wire format, the rotation/mirror traps, the pairing contract, the bundle/TCC rules — remains binding and
unchanged.

## Feasibility critique (coordinator, 2026-11-15 00:20 — honest)

Odds as designed, before any probe data: **~40–50% that the stereo pipeline reaches "locked to the guitar"
quality; ~70% that it reaches "something draws near the guitar" — which is exactly anti-goal #1.** The detector
port is not the risk. The optics are, in two specific places:

1. **Pinhole-on-fisheye — the doc's "biggest technical risk" is bigger than treated.** The MVP's math worked
   because the webcam is a normal lens. The glasses' tracking cameras are fisheye ("fisheye624"); the neck sits
   low in frame where distortion is worst. A pinhole approximation there does not produce small errors — it
   produces a neck axis that visibly detaches from the guitar at the endpoints. Self-calibrating rig extrinsics
   from one planar marker (4 coplanar points, ~65 mm baseline, ~1.5 m) is planar-degenerate and noisy, and
   "re-estimate lazily each session" makes that noise the permanent foundation of every millimeter claimed.
   Mitigation if this path survives the probe: one-time checkerboard intrinsics (the doc already tolerates it),
   a distortion term (not a pinhole guess), and marker-derived extrinsics as a seed only.
2. **Marker visibility through the glasses at playing position is unverified.** The fret-14 clip was designed
   for an audience-facing webcam. From the player's POV the camera axes are near-parallel to the neck: grazing
   angle, possible hand occlusion — and **both eyes must see the marker simultaneously or stereo is dead**. The
   contract's `pose == nil` semantics turn one-eye loss into a full overlay fade (blinking during normal play).
   Also undefined as written: the projection path from rig-frame 3D to a locked 2D overlay (which pane, whose
   intrinsics), mono fallback behavior, and what `confidence` measures.
3. (Tractable.) Hand-porting ArUco in Swift/Accelerate — 500–800 lines, ≤5 ms/eye is plausible on 480×640 gray,
   and the algorithm is proven by the MVP. Real work, not a miracle.

**Cheapest decisive step: the probe.** Run XRealProbe, clip the marker at fret 14, hold the guitar at the real
playing position, dump both eyes. Thirty minutes answers risks 1 and 2 with data instead of guesses, and the
same frames test the hand-tracking alternative below. No tracker code should be written before it.

## Hand-tracking alternative (evaluated; decision OPEN)

Question asked (user): is hand tracking easier than fretboard tracking using existing open source? Honest
answer: **as a technology, categorically yes; as a substitute for this product, no.**

- **No off-the-shelf fretboard tracker exists.** ArUco is the only mature open-source piece in the current
  plan, and it is being hand-ported precisely to avoid OpenCV. Vision-based guitar hand/fret prior art
  (GuitarFrethandDataset, FretVision, Song2Tab) is datasets and papers, not runnable software. (FretNet,
  despite the name, is audio tablature transcription — verified.)
- **Hand tracking has two real open-source options.** Apple Vision `VNDetectHumanHandPoseRequest`: 21
  landmarks, reported ~4–8 ms per call on Apple Silicon (ANE), on-device, and — decisive in this repo — **zero
  third-party dependencies**, so it satisfies the Swift-6/zero-dependency constraint off the shelf (~50 lines
  of code). MediaPipe Hands: same 21-landmark topology, cross-platform, but a real third-party dependency
  (violates the repo constraint unless the user waives it).
- **It answers a different question.** Hand landmarks locate the hand, not the fretboard; they cannot draw
  frets locked to the guitar by themselves. They can (a) draw a hand skeleton over the mirror; (b) combined
  with the marker-derived neck axis — even mono — compute which fret the hand is near; (c) if the marker fails
  through the glasses, reframe the demo as hand guidance.
- **Shared, unverified domain risk.** Both paths ride the same unproven input: 480×640 **grayscale fisheye**
  from the player's POV. ML hand models are trained on RGB normal-lens webcams; grayscale usually survives
  (skin contrast), but fisheye + extreme viewpoint + the self-occluding playing grip is genuine domain shift.
  "Probably works" is the honest status until probe frames are run through a `VNDetectHumanHandPoseRequest`
  (same probe, second experiment, ~15 lines).

**Candidate approaches after the probe:**

- **A — Stereo marker (as designed).** Keep only if the probe shows the marker big and clean in both eyes at
  once, and only with the calibration fixes above plus a defined mono fallback.
- **B — Mono marker + hand tracking (coordinator's pick).** Neck axis from the marker in one eye; fret index
  from Vision hand landmarks against that axis. Uses the two cheapest proven pieces, skips the entire
  stereo/rig-calibration tower, and best matches the stated priority order (simplicity first). Recommended.
- **C — Hand-tracking pivot.** Drop the marker; hand skeleton over the mirror. Fastest to *something*, but
  abandons G1/G3 (frets locked to the guitar) and changes the product. Only if the probe shows the marker
  unusable.

## Decision gate

The probe (30 min, glasses + the existing XRealProbe binary) runs before any tracker code, and its results
select A/B/C. **Decision pending the user.**
