# Fretboard Tracking — Person 2 (computer only: geometry, guitar model, app) Plan

**Spec:** `docs/superpowers/specs/2026-11-15-fretboard-tracking-design.md` — facts, contract and hazards there are
authoritative. Read it first.

**Why this split:** Person 2 has no glasses and no guitar, so every task here is testable on a computer: synthetic
stereo images rendered through the real lens model, plus Person 1's captured datasets run offline. Live checks go to
Person 1 as checklists.

**Global rules:** TDD. Own `Sources/XRealMirrorApp/**`, `Tests/XRealMirrorAppTests/**`, `scripts/**`, `tools/guitar/**`
and the new `fixtures/markers-synthetic/**` (shared read-only with Person 1's tests). Code against the spec's
contract; until Person 1's Task 1 lands, compile against a scratch stand-in and **don't push** anything that needs the
new types (pushing early breaks `main` for Person 1). Commit per task.

## Tasks (in order; 1–3 need nothing from Person 1)

### Task 1 — Synthetic stereo marker fixtures (unblocks Person 1's detector tests)
- `scripts/render-marker-fixtures.swift` (or a test-support target): place the three real markers (bit patterns from
  the spec, 60 mm, white quiet zone, paper) at known 3-D poses, render both eyes through `StereoCalibration`'s fisheye
  model at 480×640 grayscale with mild blur/noise, write `fixtures/markers-synthetic/{left,right}_N.png` +
  `truth.json` (per pair: each marker's 4 corner pixels per eye in contract order, and its 3-D pose).
- Poses: distances 25–90 cm, yaw/pitch up to ±50°, image positions out to the fisheye edge, some partly off-frame.
- Tests: `testFixtureCornersReprojectFromTruthPose` (the renderer and the lens model agree to < 0.01 px).

### Task 2 — F600 fretboard geometry (pure)
- `Fretboard.swift`: from `tools/guitar/f600.json` (start with spec values: scale 634, nut 43 mm, 20 frets; replace
  with Person 1's tape numbers when they arrive): fret *k* x = `634·(1−2^(−k/12))`, fretboard edges (taper nut → 12th),
  six string lines (nut spread → saddle spread), all in the guitar frame (spec: origin nut centre, +x to bridge, +y to
  treble, +z out of the fretboard).
- Tests: `testTwelfthFretIsHalfTheScale`, `testFretSpacingShrinks`, `testStringsFanOutTowardTheBridge`,
  `testHighEIsOnPlusY`.

### Task 3 — Marker pose (stereo + single eye)
- `MarkerPose.swift`: (a) stereo: triangulate the 4 corners with `StereoCalibration.triangulate` → marker plane, centre,
  axes; side-length check (60 mm); (b) single eye: planar pose from 4 corners + known 60 mm (IPPE or homography
  decomposition on unprojected rays), resolving the two-fold ambiguity by reprojection error.
- Tests on Task 1 fixtures: stereo pose error < 2 mm / 1°, triangulated side 60 ± 0.5 mm; single-eye < 5 mm / 2°;
  `testMismatchedMarkerIDsAreNotTriangulated`.

### Task 4 — Guitar model + one-time setup
- `GuitarModel.swift`: rigid marker map (each marker's corners in the guitar frame) + fretboard placement, saved as
  JSON next to the measurements. `GuitarSetup` builds it from a still capture: average triangulated corners over the
  pairs (reject outliers), then fix the guitar frame from ID 9 (nut end), the 7/8 midpoint (neck axis) and the 7/8
  normal (fretboard normal) plus the tape offsets.
- Tool: `XRealProbe`-style CLI or test entry that runs setup on Person 1's `setup-still` dataset and writes
  `tools/guitar/f600-markers.json`.
- Tests: synthetic setup recovers a known map < 1 mm; `testSetupRejectsMovingGuitar` (pose spread too large → error).

### Task 5 — GuitarTracker (live pose)
- Kabsch/Umeyama fit of all visible corners (≤ 12) to the model → 6-DoF pose; 1 marker → its own pose; none → hold
  last pose ≤ 0.5 s then report lost. Smoothing: 1€ on position, slerp-based 1€ on rotation.
- Tests: pose from any subset {7,8,9} of synthetic markers < 2 mm; `testHoldThenLose`; `testOutlierMarkerIgnored`
  (one marker with a wrong pose doesn't drag the fit — RANSAC over markers or residual gate).

### Task 6 — Fingertip on the fretboard
- `FingerOnFretboard.swift`: transform each `Hand3D` fingertip (thumb–little tips) into the guitar frame → nearest
  string (by y), fret slot (between fret k−1 and k, by x), height above the fretboard (z). "Pressing" = height below a
  threshold tuned on Person 1's `play` dataset (report the histogram, don't guess the number).
- Tests: synthetic fingertips at known (string, fret, height); edge cases (off the neck, beyond fret 20, behind nut).

### Task 7 — Drawing
- 3-D pane: fretboard outline, nut, frets, strings as thin lines in `Hands3DScene` (guitar-frame → camera via the
  tracked pose); marker squares (debug toggle).
- 2-D overlay: project nut/frets/strings into each eye with the fisheye model (sample each line into short segments —
  straight lines curve in a fisheye), drawn under the hand skeleton; reuse `HandOverlayNSView` patterns (aspect-fit,
  flipped view, render test).
- Readout: per fingertip "index: A string, fret 2, pressing".
- Tests: projection of a known fret line matches fixture pixels; overlay render test (line lands where projected).

### Task 8 — Offline verification on Person 1's datasets + push-script update
- `scripts/push-live-frames.sh`: add an optional dataset-name argument → `live-probe-frames/<name>/` (Person 1 uses it
  in their Task 3).
- `LiveFrameFretboardTests` (skips without `XREAL_PROBE_PNGS`): runs Person 1's detector + Tasks 3–6 on each dataset
  and prints: marker side length (60 ± 2 mm), inter-marker distance stability (± 2 mm), app-measured nut→12th
  (317 ± 5 mm), pose availability under occlusion, false detections on `clutter` (must be 0), ms/pair.
- Report the numbers to Person 1 and hand them the Task 6 live checklist from their plan.

## Hand-offs

| When | Person 2 → Person 1 | Person 1 → Person 2 |
|---|---|---|
| Start | Task 1 fixtures pushed (`fixtures/markers-synthetic/`) | Task 1 contract types pushed |
| Early | push-script dataset names (Task 8 part 1) | tape numbers (their Task 2); datasets (their Task 3) |
| End | live checklist + offline report | live results |
