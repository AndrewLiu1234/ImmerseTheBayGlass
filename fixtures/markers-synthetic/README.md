# Synthetic stereo marker fixtures (fretboard stage, Person 2 Task 1)

20 stereo pairs rendered through the calibrated Air 2 Ultra fisheye model (`StereoCalibration.xrealAir2Ultra`):
the three real ArUco markers (IDs 7/8/9, 60 mm black square, 90 mm paper) on a simple guitar (fretboard, headstock,
top) plus image-space clutter, 2×2 supersampled, mild blur, sensor noise.

| Pairs | Kind | What it tests |
|---|---|---|
| 0–7 | `frontal` | guitar facing the cameras (like IMG_3385), 35–90 cm, tilted ≤ 40°, rolled |
| 8–15 | `playing` | the player's own view: body markers at 46–77° incidence, headstock marker mostly hidden |
| 16–19 | `clutter` | no markers at all (false-positive set) |

`truth.json`, per pair: guitar pose (left-camera frame), each marker's placement, and per eye each marker's
`visible` flag, `incidenceDeg`, and the four black-square corners `cornersPx` in **contract order** (printed
top-left, top-right, bottom-right, bottom-left).

Pixel convention: OpenCV — pixel (u, v) has its centre at integer (u, v). Contract-normalized = (px + 0.5) / size.

Regenerate (deterministic): `GENERATE_MARKER_FIXTURES=1 swift test --filter MarkerFixtureTests/testGenerateFixtures`
(~80 s). Renderer: `Tests/XRealMirrorAppTests/Support/MarkerFixtureRenderer.swift`. Owner: Person 2; read-only for
Person 1's detector tests.
