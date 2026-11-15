# Fretboard Tracking — Person 1 (Andrew: glasses, guitar, marker core) Plan

**Spec:** `docs/superpowers/specs/2026-11-15-fretboard-tracking-design.md` — facts, contract and hazards there are
authoritative. Read it first.

**Why this split:** Person 1 has the glasses and the guitar, so Person 1 owns everything that needs them (measuring,
capturing, live checks) plus the camera-side marker detector in `Sources/XRealVision/**` (their lane, next to the
hand detector). Person 2 has only a computer and builds all geometry/app code against synthetic data and Person 1's
captures.

**Global rules:** TDD for code. Own only `Sources/XRealVision/**`, `Tests/XRealVisionTests/**`. Never commit a broken
build. Commit per task on `main`. End commits with the Co-Authored-By line.

## Order (Person 2 is blocked on Task 1 and Task 3 — do those first)

### Task 1 — Contract types, pushed immediately (≈30 min)
- Add `MarkerObservation`, `EyeMarkers`, `StereoMarkers` (**with public inits**), `ArucoDictionary.markers`, and a
  stub `StereoMarkerTracker` + delegate exactly as in the spec's contract (tracker may emit empty `StereoMarkers` until
  Task 5).
- Test `testArucoPatternsMatchThePrintedPDFs`: pins the three 4×4 patterns from the spec's Facts table (rows
  top→bottom, `true` = white). If you disagree with a pattern, stop and report — don't edit it to pass.
- Push to `main` as soon as it's green. This unblocks Person 2's push of everything that compiles against it.

### Task 2 — Tape measurements + placement check (no code, ≈15 min)
Send Person 2 these numbers (mm) — Person 2 writes `tools/guitar/f600.json`:
1. nut → 12th fret (expect 317), fretboard width at nut (expect 43) and at fret 12
2. low-E → high-E string spread at the nut and at the saddle
3. ID 9: bottom edge (nut side) → nut distance; sideways offset of its centre from the neck centreline
4. ID 7 and ID 8: which fret their centres line up with; distance from the fretboard edge to each marker's near edge
5. Confirm: ID 8 is on the **bass** side and ID 7 on the **treble** side (as inferred from the photo)
6. Print check: each printout's 100 mm ruler reads 100 mm (otherwise the markers aren't 60 mm)

### Task 3 — Capture datasets (glasses + guitar, ≈20 min)
Use the probe's `--pairs` option and `scripts/push-live-frames.sh <dir> <dataset-name>` (Person 2 adds the name
argument; until then push one dataset at a time). Each dataset: a one-line note in `run-info.txt` of what was done.
- **`setup-still`** — 60 pairs, guitar held still in playing position, all three markers visible in both eyes.
- **`play`** — 200 pairs, playing position, fretting G / C / D / Em / Am, strumming hand moving.
- **`distance`** — 3 × 40 pairs with the guitar at ≈30, 50, 80 cm from the glasses.
- **`occluded`** — 60 pairs with each marker covered in turn by a hand.
- **`clutter`** — 40 pairs of the room/desk with **no** markers (false-positive test set).

### Task 4 — MarkerDetector (per eye)
Pipeline per the spec: optional undistort LUT → `VNDetectRectanglesRequest` (loose) → homography → 6×6 grid sample →
border check → ID match over 4 rotations (Hamming ≤ 1) → sub-pixel corner refinement → contract corner order
(top-left of the printed marker first). Vision is bottom-left origin — flip.
Pinned tests (synthetic fixtures from Person 2's `fixtures/markers-synthetic/`, plus your captures):
- `testFindsAllThreeMarkersInSyntheticPairs` (recall ≥ 95 % at ≥ 24 px)
- `testCornerErrorSubPixel` (< 0.3 px vs fixture ground truth)
- `testNoFalseIDsOnClutter` (zero detections on `clutter` + IMG_3385's non-marker rectangles)
- `testCornerOrderFollowsPrintedOrientation` (rotate the fixture 90/180/270 → same physical corner first)
- `testMirroredMarkerIsRejected`
- `testPaperOutlineResolvesToBlackSquare`
- `testDetectorBudget` (median ≤ 3 ms per 480×640 eye; real budget checked live)

### Task 5 — StereoMarkerTracker
Same rules as `StereoHandTracker`: `accept` O(1) non-blocking, latest-wins, every Nth pair, own serial queue; delegate
on that queue. Tests mirror `StereoHandTrackerTests` (non-blocking with a blocked fake, decimation by pair count,
never sequence parity).

### Task 6 — Live verification on the glasses (after Person 2's app tasks land)
`git pull && ./scripts/check-bundle.sh && open dist/XRealMirror.app`, then check and report:
- [ ] pairs/s ≈ 60 with hands + markers running
- [ ] fret lines sit on the real frets in both eye panes (photo of the screen for each pane)
- [ ] the 3-D pane shows the fretboard where the guitar is, moving with it
- [ ] cover each marker in turn: the fretboard stays (from the others); cover all: holds ≤ 0.5 s then hides
- [ ] fingertip readout names the right string/fret for G, C, D, Em, Am
- [ ] report nut→12th as measured by the app (expect 317 ± 5 mm)
