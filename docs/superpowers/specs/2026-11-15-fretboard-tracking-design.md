# Fretboard Tracking — Design

**Date:** 2026-11-15. Stage 4 of XRealMirror (stage 2 = 2-D hands, stage 3 = live 3-D hands, both on main).
**Status:** Draft from Person 2's session at the user's direction ("brainstorm how to do it, split into Person 1 /
Person 2"). Needs Person 1's OK on the interface contract before either lane starts.

## Intent

The app should **see the guitar's fretboard** in 3-D, live, from both glasses cameras: where the nut, every fret and
every string are, relative to the glasses. Combined with stage 3's 3-D fingertips, that answers the question the
product needs: *which string and fret is each fingertip on, and is it pressing or hovering?*

Approach the user chose: **Apple Vision's rectangle detector + three 60 mm ArUco markers** on the guitar.

## Facts this design rests on (all checked, not assumed)

| Fact | Value | Source |
|---|---|---|
| Markers | ArUco **IDs 7, 8, 9**, 4×4 data bits + 1-cell black border (OpenCV `DICT_4X4_50`, the set the earlier camera bridge used) | `~/Downloads/aruco-{marker,8,9}-60mm-A4.pdf`; ImmerseTheBayWinners `tools/camera-vision/camera_bridge.py:43` |
| Marker size | **60.0 mm** outer edge of the black square (measured off all three PDFs: 60.0 / 60.1 / 60.1 mm) | the PDFs |
| Bit patterns (rows top→bottom as printed upright, `1` = white) | ID 7: `1100 0100 1111 0010` · ID 8: `1111 1110 1101 1010` · ID 9: `1100 1111 0101 0110` | read off the PDFs at 300 dpi; ID 7 cross-checked by eye |
| Placement | **ID 9** on the headstock face just above the nut; **ID 8** on the upper bout, bass side of the neck; **ID 7** upper bout, treble side; 7 and 8 flank the neck at the neck/body joint | `~/Downloads/IMG_3385.HEIC` (bass/treble side inferred from the pickguard — Person 1 confirms) |
| Guitar | **Yamaha F600**: scale **634 mm**, nut width **43 mm**, neck joins body at fret **14**, 20 frets | two retailer spec listings agree (one guide says 650 mm — outlier); Person 1 verifies with a tape |
| Fret positions | fret *k* at `634 · (1 − 2^(−k/12))` mm from the nut (12th = 317 mm) | equal temperament |
| Stereo calibration | already in `Sources/XRealMirrorApp/StereoCalibration.swift` (fisheye lenses + 13.6 cm baseline, validated on live hand frames: rays meet within 7 mm) | stage 3 |
| Vision rectangle detector on the photo | strict settings found **1 of 3** markers (the angled ones fail the squareness test); loose settings found **all 3 + 10 false rectangles** (laptop, papers, the markers' own inner cells) and outlined the **paper**, not the black square, on the headstock. 7 ms on 1200×1600 | Person 2's run on IMG_3385 |
| Marker size on the glasses cameras | f ≈ 239 px → a 60 mm marker is ≈ 36 px at 40 cm (body markers), ≈ 18 px at 80 cm (headstock while playing) ≈ 3 px per bit cell | arithmetic |

**Consequence:** the rectangle detector is a *candidate finder only*. Every candidate must be verified by decoding
its bits (rejects false rectangles, yields the ID and the corner order) and its corners refined to sub-pixel before
they're worth triangulating.

## Goals

- **G1** Detect markers 7/8/9 in both eyes, with ID, ordered corners (sub-pixel), at ≥ 30 pairs/s alongside hand
  tracking (combined budget 15 ms/pair).
- **G2** Guitar pose (6-DoF) every frame from whichever markers are visible: 3 → best, 2 → fine, 1 → still a full
  pose from that marker's own 4 corners.
- **G3** Fretboard model: nut, frets 0–20, six strings, as 3-D lines in the glasses' frame; drawn in the 3-D pane and
  projected onto both eye panes.
- **G4** Fingertip → (string, fret, height above the fretboard) for each tracked fingertip.
- **G5** One-time guitar setup that needs only a tape measure and a 2-second still capture.

## Non-goals

No automatic fret/string detection from the image (a later upgrade, see Approaches), no chord recognition or
scoring, no audio, no other guitars' presets beyond the F600 numbers (the setup step makes any guitar work).

## Approaches considered

1. **Chosen: Vision rectangles → our own bit decode + corner refine → stereo triangulation → rigid guitar model.**
   Uses the user's chosen detector, zero dependencies, and the stereo math stage 3 already validated.
2. Rejected for v1: **OpenCV ArUco** — the most robust off-the-shelf marker detector, but a C++ dependency the repo
   has deliberately avoided (stage 2 spec, G4). Kept as the fallback if Vision's candidates prove too unreliable.
3. Rejected for v1: **markerless** (detect nut/frets/strings as lines). Fragile under hands, glare and fisheye
   curvature; worth adding later as *refinement* on top of the marker pose, not as the base.
4. **Stereo vs single-camera pose per marker: both.** Stereo triangulation of the 4 corners needs no marker size and
   turns size into a free check (side must come out 60 mm). Single-camera planar pose (homography / IPPE, known 60 mm)
   covers markers only one eye sees. Prefer stereo when available.

## Architecture

```
StereoFrame (stage 1)                                 StereoHands → Hand3D (stage 3)
   │ (same tracker queue, every other pair)                       │
   ▼                                                              │
Person 1 — XRealVision (camera / marker core)                     │
   MarkerDetector, per eye:                                       │
     1. optional undistort LUT (straight edges for Vision)        │
     2. VNDetectRectanglesRequest, loose (aspect 0.5–1, quad      │
        tolerance ~30°, ≤15 obs; ROI around last pose)            │
     3. per candidate: homography → sample 6×6 grid → border      │
        check → match IDs {7,8,9} × 4 rotations (Hamming ≤ 1)     │
        → reject non-markers; paper-outline → search inward       │
     4. sub-pixel corners: fit the 4 black-square edges           │
   StereoMarkerTracker → StereoMarkers                            │
   ──────────── contract ─────────────                            │
Person 2 — XRealMirrorApp (geometry / app)                        │
   MarkerPose: stereo-triangulate corners | single-eye IPPE       │
   GuitarModel: rigid marker map + fretboard frame (setup once)   │
   GuitarTracker: Kabsch fit of visible corners → pose, 1€, hold  │
   Fretboard: nut / frets / strings in 3-D  ◄─────────────────────┤
   FingerOnFretboard: fingertip → (string, fret, height) ◄────────┘
   Render: 3-D pane lines + 2-D overlay (fisheye projection)
```

## Interface contract (the only cross-lane surface; Person 1 implements, both OK before work starts)

```swift
// Sources/XRealVision — new, additive (stage 1–3 contracts unchanged)
public struct MarkerObservation: Sendable {
    public var id: Int                       // 7, 8 or 9
    public var corners: [SIMD2<Float>]       // exactly 4, normalized 0...1, origin TOP-LEFT of the upright image,
                                             // ArUco order: the printed marker's top-left, top-right, bottom-right,
                                             // bottom-left (so orientation survives rotation of the guitar)
    public var hammingDistance: Int          // bits corrected when decoding (0 = exact)
    public init(id: Int, corners: [SIMD2<Float>], hammingDistance: Int)
}
public struct EyeMarkers: Sendable { public var markers: [MarkerObservation]; public init(markers: [MarkerObservation] = []) }
public struct StereoMarkers: Sendable {
    public var leftEye: EyeMarkers
    public var rightEye: EyeMarkers
    public var sequence: UInt16
    public var timestampMicros: UInt64
    public init(leftEye: EyeMarkers, rightEye: EyeMarkers, sequence: UInt16, timestampMicros: UInt64)  // PUBLIC init:
}                                                // stage 2's StereoHands lacked one, which blocked app-side tests
public enum ArucoDictionary {
    /// 4×4 data bits per ID, rows top→bottom as printed upright, true = white. Pinned by a test against the PDFs.
    public static let markers: [Int: [[Bool]]]   // 7, 8, 9 — values in "Facts" above
}
public protocol StereoMarkerTrackerDelegate: AnyObject {
    func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers)
}
public final class StereoMarkerTracker: @unchecked Sendable {
    public init(processEveryNthPair: Int = 2)
    public weak var delegate: StereoMarkerTrackerDelegate?
    public func accept(_ frame: StereoFrame)     // non-blocking, O(1), latest-wins — same rules as StereoHandTracker
}
```

Guitar frame (Person 2's model, written here so both read the same words): origin at the **centre of the nut on the
fretboard surface**; **+x** along the strings toward the bridge; **+y** across the neck toward the **treble** (high-E)
side; **+z** out of the fretboard, toward the strings. Metres.

## Guitar setup (once per guitar; Person 1 measures, Person 2's code consumes)

1. **Tape measurements** (`tools/guitar/f600.json`, Person 2 writes the file from Person 1's numbers):
   - nut → 12th fret (expect 317 mm; confirms the 634 mm scale)
   - fretboard width at the nut (expect 43 mm) and at the 12th fret
   - string spread E–E at the nut and at the saddle
   - ID 9: distance from its bottom edge (the edge nearest the nut) to the nut, and its sideways offset from the neck
     centreline
   - IDs 7 & 8: which fret their centres line up with, and their distance from the fretboard edge
2. **Still capture**: guitar held still, all three markers in both eyes, `XRealProbe --pairs 60`. Person 2's setup
   tool triangulates every corner, averages over the 60 pairs and stores the **rigid marker map** (each marker's
   corners in the guitar frame). Measuring the map instead of assuming it absorbs headstock angle and marker
   placement error.
3. The fretboard frame is then fixed from the map + tape numbers: x-axis = from the ID 9-derived nut point toward the
   midpoint of 7/8 (projected to the fretboard line), z = average normal of markers 7 & 8, y = z × x.

## Hazards (each gets a pinned test in the lane plans)

1. **False rectangles** (laptop, paper, the markers' own inner cells) — only decoded IDs 7/8/9 may leave the detector.
2. **Paper outline instead of the black square** — the decoded border must be black; otherwise search inward.
3. **Corner order / mirror** — corners must follow the printed marker's orientation; a mirrored decode (wrong
   handedness of the corner order) must fail, not pass rotated.
4. **Fisheye curvature** — Vision assumes straight edges; worst for the headstock near the image edge. Undistort (or
   refine corners on the distorted edges with the lens model).
5. **Tiny headstock marker** (≈18 px at 80 cm) — decode needs ≥ ~3 px/cell; below that, report nothing rather than
   guess; the single-marker fallback keeps the pose alive from 7/8.
6. **Occlusion by the fretting/strumming hand** — 1-marker fallback + short pose hold; never extrapolate > 0.5 s.
7. **Calibration from another unit** — shows up as fret lines sliding along the neck; the nut→12th = 317 mm check
   catches it; a single scale factor fixes it.
8. **Vision coordinates** are bottom-left origin — flip to the contract's top-left (same trap as stage 2).

## Verification

- **Synthetic (no glasses):** render the three real bit patterns into both eyes through the fisheye model at known
  poses (Person 2 builds this renderer; Person 1's detector tests use the same images): detection recall ≥ 95 % at
  ≥ 24 px marker size, corner error < 0.3 px, zero false IDs on clutter images (IMG_3385 + probe frames without
  markers), pose error < 2 mm / 1°.
- **Live dumps (Person 1 records, Person 2 runs offline):** marker side length from stereo **60 ± 2 mm**;
  inter-marker distances stable ± 2 mm across frames; nut→12th **317 ± 5 mm**; detection + hands ≤ 15 ms/pair.
- **On the glasses (Person 1):** projected fret lines sit on the real frets in both panes; fingertip readout names
  the right string/fret for G, C, D, Em, Am shapes.
