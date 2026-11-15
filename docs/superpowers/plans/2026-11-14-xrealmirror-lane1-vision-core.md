# XRealMirror — Lane 1 (Vision Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `XRealVision` library: descramble, orient, and stereo-pair the XREAL Air 2 Ultra's raw UVC frames into `StereoFrame`s the app can display — fully unit-tested without the glasses.

**Architecture:** Pure decode core (`XRealFrameDecoder`, byte-array in/out, no I/O) + a pure pairing state machine (`StereoPairer`) + a thin AVFoundation wrapper (`StereoCamera`) whose behavior the probe verifies live. All hardware constants live in `FrameLayout`.

**Tech Stack:** Swift 6.3 (language mode 6), SwiftPM, XCTest, Accelerate (vImage), AVFoundation, CoreGraphics.

**Spec:** `docs/superpowers/specs/2026-11-14-xrealmirror-design.md` — the interface contract, constants, and hazards in it are authoritative. Read it first.

## Global Constraints

- Code against the design doc's Interface contract exactly — those names and signatures are what Lane 2 (App & Probe) compiles against. Do not rename or re-signature anything without stopping and reporting.
- TDD strictly: for every behavior, write the failing test, watch it fail, then implement. No implementation without a red test first.
- Own only `Sources/XRealVision/**` and `Tests/XRealVisionTests/**`. Never touch Lane 2's paths (`Sources/XRealMirrorApp/**`, `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md`) or `Package.swift` / `.gitignore`. If a change seems to need them, stop and report.
- Never commit a tree that does not build: every task's final verification is `swift build` green plus `swift test` green. Lane 2 builds the whole package at any time.
- Task 0 already ran: the package scaffold, `.gitignore`, and placeholder files exist and `swift build` is green. Delete `Sources/XRealVision/Lane1Placeholder.swift` in Task 1.
- Swift 6 concurrency: `CGImage` is immutable but not `Sendable` — where a queue boundary carries it, annotate with `@unchecked Sendable` and a one-line comment. AVFoundation delegate callbacks are `nonisolated`.
- Hardware facts come only from `FrameLayout` / the spec. If the reorderMap permutation test fails, **stop and report** — do not invent or reorder values.
- Mirror-only scope: no Vision, no calibration, no 3D. If it looks like scope creep, stop and report.
- Work on `main` in the shared working tree; commit per task; if `git` reports `index.lock`, wait and retry. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

These are the five ways this lane most plausibly ships wrong images; each has a pinned test named below (spec §Hazards).

1. Mirrored images — transpose instead of 90° rotation (the guide's explicit trap) → `testLeftAndRightRotationsAreNotMirrors` (Task 3).
2. Bad reorderMap transcription — the single most likely constant to be wrong → `testReorderMapIsPermutationOf0To127` (Task 1); red means stop-and-report.
3. Camera ID read from the wrong offset (`+0x3B` reads `0x00` on real hardware) → `testMetadataOffsets` pins `+0x3A` (Task 2).
4. All-zero warmup frames mis-handled as errors — they are valid frames; skip logic lives in the camera, not the decoder → `testDecodeAllZeroFrameIsValid` (Task 2) + skip-first-6 in Task 4.
5. Align misdetection — wrong sync block ⇒ garbage images that still "decode" → `testRecoverAlignFindsSmallestSumBlock` (Task 1).

## File Map

- Create: `Sources/XRealVision/Frame.swift`, `FrameDecoder.swift`, `StereoCamera.swift`
- Delete: `Sources/XRealVision/Lane1Placeholder.swift` (in Task 1)
- Test: `Tests/XRealVisionTests/FrameDecoderTests.swift`, `StereoPairerTests.swift`

---

### Task 1: FrameLayout constants + unpermute + align recovery

**Files:**
- Create: `Sources/XRealVision/FrameDecoder.swift`
- Delete: `Sources/XRealVision/Lane1Placeholder.swift`
- Test: `Tests/XRealVisionTests/FrameDecoderTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–3 here and by Lane 2): `FrameLayout` (all constants), `XRealFrameDecoder.unpermute(payload:align:)`, `XRealFrameDecoder.recoverAlign(payload:)`, `DecodedFrame` placeholder-free (the struct is completed in Task 2 — for now `DecodedFrame` may be declared in Task 2; Task 1 needs only `FrameLayout`, `unpermute`, `recoverAlign`).

- [ ] **Step 1: Write the failing tests** in `Tests/XRealVisionTests/FrameDecoderTests.swift`. Put the map verbatim in `FrameLayout.reorderMap` first (it is 128 values; this file's test proves it), then these tests:

```swift
import XCTest
@testable import XRealVision

final class FrameDecoderTests: XCTestCase {
    // Deterministic pseudo-random scan fill so byte POSITIONS differ (a per-block constant would
    // survive any permutation and prove nothing).
    private func pattern(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8((($0 &* 131) &+ 17) & 0xFF) }
    }

    // Hardware permutation math, re-derived from the spec for the test's own use.
    private func permute(scan: [UInt8], align: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for t in 0..<FrameLayout.blocks {
            let src = t * FrameLayout.blockBytes
            let dst = FrameLayout.reorderMap[(align + t) % FrameLayout.blocks] * FrameLayout.blockBytes
            raw.replaceSubrange(dst..<(dst + FrameLayout.blockBytes),
                                with: scan[src..<(src + FrameLayout.blockBytes)])
        }
        return raw
    }

    func testReorderMapIsPermutationOf0To127() {
        XCTAssertEqual(FrameLayout.reorderMap.count, 128)
        XCTAssertEqual(Set(FrameLayout.reorderMap).count, 128)
        XCTAssertEqual(FrameLayout.reorderMap.min(), 0)
        XCTAssertEqual(FrameLayout.reorderMap.max(), 127)
    }

    func testLayoutConstants() {
        XCTAssertEqual(FrameLayout.sensorWidth, 640)
        XCTAssertEqual(FrameLayout.sensorHeight, 480)
        XCTAssertEqual(FrameLayout.uprightWidth, 480)
        XCTAssertEqual(FrameLayout.uprightHeight, 640)
        XCTAssertEqual(FrameLayout.blocks, 128)
        XCTAssertEqual(FrameLayout.blockBytes, 2_400)
        XCTAssertEqual(FrameLayout.imageBytes, 307_200)
        XCTAssertEqual(FrameLayout.metadataOffset, 307_200)
        XCTAssertEqual(FrameLayout.paddingOffset, 307_840)
        XCTAssertEqual(FrameLayout.frameBytes, 308_480)
    }

    func testUnpermuteRestoresLogicalOrder() {
        let scan = pattern(FrameLayout.imageBytes)
        for align in [0, 1, 37, 127] {
            let raw = permute(scan: scan, align: align)
            XCTAssertEqual(XRealFrameDecoder.unpermute(payload: raw, align: align), scan,
                           "align \(align) round-trip")
        }
    }

    func testRecoverAlignFindsSmallestSumBlock() {
        var scan = [UInt8](repeating: 0xFF, count: FrameLayout.imageBytes)
        // Logical block 0 is the sync block (black vignette): all zeros, unique smallest 128-byte sum.
        scan.replaceSubrange(0..<FrameLayout.blockBytes,
                             with: [UInt8](repeating: 0, count: FrameLayout.blockBytes))
        for align in [0, 5, 63, 127] {
            let raw = permute(scan: scan, align: align)
            XCTAssertEqual(XRealFrameDecoder.recoverAlign(payload: raw), align, "align \(align)")
        }
    }

    func testRecoverAlignReturnsNilForWrongSize() {
        XCTAssertNil(XRealFrameDecoder.recoverAlign(payload: [UInt8](repeating: 0, count: 100)))
    }
}
```

`FrameLayout.reorderMap` (verbatim from the spec — do not reorder, do not "fix" a failing test by changing these):

```swift
public static let reorderMap: [Int] = [
    119, 54, 21, 0, 108, 22, 51, 63, 93, 99, 67, 7, 32, 112, 52, 43,
    14, 35, 75, 116, 64, 71, 44, 89, 18, 88, 26, 61, 70, 56, 90, 79,
    87, 120, 81, 101, 121, 17, 72, 31, 53, 124, 127, 113, 111, 36, 48,
    19, 37, 83, 126, 74, 109, 5, 84, 41, 76, 30, 110, 29, 12, 115, 28,
    102, 105, 62, 103, 20, 3, 68, 49, 77, 117, 125, 106, 60, 69, 98, 9,
    16, 78, 47, 40, 2, 118, 34, 13, 50, 46, 80, 85, 66, 42, 123, 122,
    96, 11, 25, 97, 39, 6, 86, 1, 8, 82, 92, 59, 104, 24, 15, 73, 65,
    38, 58, 10, 23, 33, 55, 57, 107, 100, 94, 27, 95, 45, 91, 4, 114,
]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FrameDecoderTests`
Expected: build errors or assertion failures (nothing to test yet). If `testReorderMapIsPermutationOf0To127` fails because the map you typed has a duplicate or missing value, STOP and report — you transcribed it wrong.

- [ ] **Step 3: Implement in `Sources/XRealVision/FrameDecoder.swift`**

Declare `FrameLayout` with all constants and the map above, and:

```swift
public enum XRealFrameDecoder {
    public static func unpermute(payload: [UInt8], align: Int) -> [UInt8]
    public static func recoverAlign(payload: [UInt8]) -> Int?
}
```

Approach (the algorithms the tests do not determine):
- `unpermute`: allocate `scan` of `imageBytes`; for `t in 0..<128`, copy `payload` from raw block `reorderMap[(align + t) % 128]` (offset `block * 2_400`) into `scan[t * 2_400 ..< (t+1) * 2_400]`. Guard `payload.count == imageBytes`, else return an empty array.
- `recoverAlign`: guard `payload.count == imageBytes`. For each raw block `b in 0..<128`, sum the first 128 bytes. `sync` = index of the minimum sum (first occurrence on ties). Precompute `inverseMap` (`inverseMap[reorderMap[i]] = i`). Return `inverseMap[sync]`.
- Delete `Lane1Placeholder.swift`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FrameDecoderTests`
Expected: all tests pass. (Do not assert a total test count — the suite is shared and grows.)

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/FrameDecoder.swift Tests/XRealVisionTests/FrameDecoderTests.swift
git rm -q Sources/XRealVision/Lane1Placeholder.swift
git commit -m "feat: FrameLayout constants, block unpermute, and align recovery

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Metadata parsing + decode + encode inverse

**Files:**
- Modify: `Sources/XRealVision/FrameDecoder.swift`
- Test: `Tests/XRealVisionTests/FrameDecoderTests.swift` (append)

**Interfaces:**
- Produces: `DecodedFrame` (all five fields), `XRealFrameDecoder.decode(_:)`, `XRealFrameDecoder.encode(upright:cameraID:sequence:align:timestampMicros:)` — Lane 2's probe consumes both.

- [ ] **Step 1: Write the failing tests** (append to `FrameDecoderTests`):

```swift
    // Inverse rotations re-derived from the spec, for building expected scans in tests.
    private func scanForLeft(upright: [UInt8]) -> [UInt8] {
        // Left is CCW: scan[c*640+r] = upright[(639-r)*480+c]
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for c in 0..<FrameLayout.sensorWidth {
            for r in 0..<FrameLayout.sensorHeight {
                scan[c * FrameLayout.sensorWidth + r] =
                    upright[(FrameLayout.sensorHeight - 1 - r) * FrameLayout.uprightWidth + c]
            }
        }
        return scan
    }
    private func scanForRight(upright: [UInt8]) -> [UInt8] {
        // Right is CW: scan[c*640+r] = upright[r*480 + (479-c)]
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for c in 0..<FrameLayout.sensorWidth {
            for r in 0..<FrameLayout.sensorHeight {
                scan[c * FrameLayout.sensorWidth + r] =
                    upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)]
            }
        }
        return scan
    }

    func testEncodeProducesFrameBytesWithPadding() {
        let upright = [UInt8](repeating: 0x7F, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.left,
                                             sequence: 0x1234, align: 9, timestampMicros: 1)
        XCTAssertEqual(frame.count, FrameLayout.frameBytes)
        XCTAssertTrue(frame[FrameLayout.paddingOffset..<FrameLayout.frameBytes].allSatisfy { $0 == 0x5C })
    }

    func testMetadataOffsets() {
        let upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let seq: UInt16 = 0xAB12
        let ts: UInt64 = 0x0102030405060708
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.right,
                                             sequence: seq, align: 0, timestampMicros: ts)
        XCTAssertEqual(UInt16(frame[FrameLayout.metadataOffset + 0x12])
                       | (UInt16(frame[FrameLayout.metadataOffset + 0x13]) << 8), seq)
        XCTAssertEqual(frame[FrameLayout.metadataOffset + 0x3A], CameraID.right)  // NOT +0x3B
        var tsBytes: UInt64 = 0
        for i in 0..<8 { tsBytes |= UInt64(frame[FrameLayout.metadataOffset + 0x3E + i]) << (8 * i) }
        XCTAssertEqual(tsBytes, ts)
    }

    func testEncodeDecodeRoundTripBothEyes() {
        let upright = pattern(FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        for cameraID in [CameraID.left, CameraID.right] {
            for align in [0, 1, 64, 127] {
                let frame = XRealFrameDecoder.encode(upright: upright, cameraID: cameraID,
                                                     sequence: 42, align: align, timestampMicros: 7)
                guard let decoded = XRealFrameDecoder.decode(frame) else {
                    XCTFail("decode returned nil (cameraID \(cameraID), align \(align))"); continue
                }
                XCTAssertEqual(decoded.cameraID, cameraID)
                XCTAssertEqual(decoded.sequence, 42)
                XCTAssertEqual(decoded.align, align)
                XCTAssertEqual(decoded.timestampMicros, 7)
                let expectedScan = cameraID == CameraID.left ? scanForLeft(upright: upright)
                                                             : scanForRight(upright: upright)
                XCTAssertEqual(decoded.scan, expectedScan, "cameraID \(cameraID), align \(align)")
            }
        }
    }

    func testDecodeRejectsWrongSize() {
        XCTAssertNil(XRealFrameDecoder.decode([UInt8](repeating: 0, count: 100)))
        XCTAssertNil(XRealFrameDecoder.decode([UInt8](repeating: 0, count: FrameLayout.frameBytes - 1)))
    }

    func testDecodeAllZeroFrameIsValid() {
        // Warmup frames are all zeros and are legitimate content — the decoder must not treat
        // them as errors; skip logic lives in StereoCamera.
        let upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.left,
                                             sequence: 0, align: 0, timestampMicros: 0)
        let decoded = XRealFrameDecoder.decode(frame)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.scan.allSatisfy { $0 == 0 })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FrameDecoderTests`
Expected: the new tests fail to compile or fail (decode/encode/`DecodedFrame` don't exist yet). Task 1's tests must still pass.

- [ ] **Step 3: Implement**

Create `Sources/XRealVision/Frame.swift` with `CameraID`, `RawEyeFrame`, `StereoFrame` exactly as in the spec contract. In `FrameDecoder.swift` add `DecodedFrame` (all five fields) and implement:

```swift
public static func decode(_ frame: [UInt8]) -> DecodedFrame?
public static func encode(upright: [UInt8], cameraID: UInt8, sequence: UInt16,
                          align: Int, timestampMicros: UInt64) -> [UInt8]
```

Approach:
- `decode`: guard `frame.count == FrameLayout.frameBytes`; `payload = Array(frame[0..<imageBytes])`; `recoverAlign` (return nil if it does); `unpermute`; parse metadata little-endian: sequence from `+0x12..13`, cameraID from `+0x3A`, timestamp from `+0x3E..45` (a manual 8-byte LE read, no Foundation dependency needed).
- `encode`: guard `upright.count == uprightWidth * uprightHeight` and `cameraID` is `CameraID.left` or `.right`; build `scan` by the inverse rotation for the camera ID (the same math as the tests' `scanForLeft`/`scanForRight`); permute `scan` into a `frameBytes`-sized buffer (the same math as `unpermute` inverted); write the metadata row (sequence LE at `+0x12`, cameraID at `+0x3A`, timestamp LE at `+0x3E`); fill `paddingOffset..<frameBytes` with `0x5C`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FrameDecoderTests`
Expected: all pass. Then `swift build` must be green.

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/Frame.swift Sources/XRealVision/FrameDecoder.swift Tests/XRealVisionTests/FrameDecoderTests.swift
git commit -m "feat: frame metadata parsing, decode, and encode test oracle

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 90° rotations + CGImage conversion

**Files:**
- Modify: `Sources/XRealVision/FrameDecoder.swift`
- Test: `Tests/XRealVisionTests/FrameDecoderTests.swift` (append)

**Interfaces:**
- Produces: `rotateLeft(_:)`, `rotateRight(_:)`, `makeCGImage(upright:)`, `makeEyeImage(scan:cameraID:)` — the app and probe display through these.

- [ ] **Step 1: Write the failing tests** (append):

```swift
    private func cgImageBytes(_ img: CGImage) -> [UInt8]? {
        guard let data = img.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }
    private func mirrorHorizontal(_ upright: [UInt8]) -> [UInt8] {
        var out = upright
        for r in 0..<FrameLayout.uprightHeight {
            for c in 0..<FrameLayout.uprightWidth {
                out[r * FrameLayout.uprightWidth + c] = upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)]
            }
        }
        return out
    }
    private func markerUpright() -> [UInt8] {
        var u = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        u[12 * FrameLayout.uprightWidth + 34] = 0xFF   // single marker pixel at (row 12, col 34)
        return u
    }

    func testRotateLeftOrientsMarkerPixel() {
        let u = markerUpright()
        XCTAssertEqual(XRealFrameDecoder.rotateLeft(scanForLeft(upright: u)), u)
    }

    func testRotateRightOrientsMarkerPixel() {
        let u = markerUpright()
        XCTAssertEqual(XRealFrameDecoder.rotateRight(scanForRight(upright: u)), u)
    }

    func testLeftAndRightRotationsAreNotMirrors() {
        // The guide's trap: a plain transpose yields a mirrored image. A mirror of an
        // asymmetric pattern must not equal the true rotation.
        let u = markerUpright()
        let scan = scanForLeft(upright: u)
        XCTAssertEqual(XRealFrameDecoder.rotateLeft(scan), u)
        XCTAssertNotEqual(XRealFrameDecoder.rotateLeft(scan), mirrorHorizontal(u))
    }

    func testMakeEyeImageChoosesRotationByCameraID() {
        let u = markerUpright()
        let left = XRealFrameDecoder.makeEyeImage(scan: scanForLeft(upright: u), cameraID: CameraID.left)
        let right = XRealFrameDecoder.makeEyeImage(scan: scanForRight(upright: u), cameraID: CameraID.right)
        XCTAssertEqual(cgImageBytes(left!), u)
        XCTAssertEqual(cgImageBytes(right!), u)
    }

    func testMakeCGImageGeometry() {
        let u = [UInt8](repeating: 0x80, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let img = XRealFrameDecoder.makeCGImage(upright: u)
        XCTAssertEqual(img?.width, FrameLayout.uprightWidth)
        XCTAssertEqual(img?.height, FrameLayout.uprightHeight)
        XCTAssertEqual(img?.bitsPerPixel, 8)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FrameDecoderTests`
Expected: the new tests fail (functions missing). Prior tests still pass.

- [ ] **Step 3: Implement**

```swift
public static func rotateLeft(_ scan: [UInt8]) -> [UInt8]    // vImageRotate90_Planar8, kRotate90DegreesCounterClockwise
public static func rotateRight(_ scan: [UInt8]) -> [UInt8]   // kRotate90DegreesClockwise
public static func makeCGImage(upright: [UInt8]) -> CGImage?
public static func makeEyeImage(scan: [UInt8], cameraID: UInt8) -> CGImage?
```

Approach (the calls the tests do not determine):
- `import Accelerate`; for each rotation, `scan.withUnsafeBufferPointer`/`withUnsafeMutableBufferPointer` around a 480×640 output buffer, then `vImageRotate90_Planar8(&src, &dst, rotationConstant, 0, vImage_Flags(kvImageNoFlags))` with the CCW constant for left and CW for right. Guard `scan.count == imageBytes`, else return `[]`.
- `makeCGImage`: `CGImage(width: uprightWidth, height: uprightHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: uprightWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(upright) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)`; return nil on wrong size.
- `makeEyeImage`: pick the rotation by `cameraID == CameraID.left` (left → CCW) else (right → CW), then `makeCGImage`. Return nil for an unknown cameraID.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FrameDecoderTests` then `swift build`
Expected: all pass, build green.

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/FrameDecoder.swift Tests/XRealVisionTests/FrameDecoderTests.swift
git commit -m "feat: per-eye 90-degree rotations and greyscale CGImage output

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: StereoPairer + StereoCamera capture wrapper

**Files:**
- Create: `Sources/XRealVision/StereoCamera.swift`
- Test: `Tests/XRealVisionTests/StereoPairerTests.swift`

**Interfaces:**
- Consumes: `CameraID`, `RawEyeFrame`, `StereoFrame`, `DecodedFrame`, `XRealFrameDecoder.decode`, `makeEyeImage`.
- Produces (Lane 2 compiles against these): `StereoPairer`, `StereoCamera`, `StereoCameraDelegate`, `XRealCameraError`, plus on `StereoCamera`: `delegate`, `rawFrameHandler: ((DecodedFrame) -> Void)?`, `static findXRealDevice()`, `start()`, `stop()`.

- [ ] **Step 1: Write the failing tests** in `Tests/XRealVisionTests/StereoPairerTests.swift`:

```swift
import XCTest
@testable import XRealVision

final class StereoPairerTests: XCTestCase {
    private func dummyImage(_ b: UInt8) -> CGImage {
        XRealFrameDecoder.makeCGImage(upright: [UInt8](repeating: b,
            count: FrameLayout.uprightWidth * FrameLayout.uprightHeight))!
    }

    func testEmitsWhenBothEyesArrive() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 5, cameraID: CameraID.left, timestampMicros: 10))
        let frame = p.accept(image: dummyImage(2), sequence: 5, cameraID: CameraID.right, timestampMicros: 10)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.sequence, 5)
        XCTAssertEqual(frame?.left.cameraID, CameraID.left)
        XCTAssertEqual(frame?.right.cameraID, CameraID.right)
        XCTAssertEqual(frame?.left.sequence, 5)
        XCTAssertEqual(p.pendingCount, 0)
    }

    func testOutOfOrderArrival() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(2), sequence: 7, cameraID: CameraID.right, timestampMicros: 1))
        XCTAssertNotNil(p.accept(image: dummyImage(1), sequence: 7, cameraID: CameraID.left, timestampMicros: 1))
    }

    func testSequenceMismatchHoldsUntilMatch() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 8, cameraID: CameraID.left, timestampMicros: 1))
        XCTAssertNil(p.accept(image: dummyImage(2), sequence: 9, cameraID: CameraID.right, timestampMicros: 1))
        let frame = p.accept(image: dummyImage(3), sequence: 8, cameraID: CameraID.right, timestampMicros: 1)
        XCTAssertEqual(frame?.sequence, 8)
        XCTAssertEqual(p.pendingCount, 1)   // seq 9's right eye still waiting
    }

    func testPendingClearedWhenOver8() {
        var p = StereoPairer()
        for i in 0..<9 {
            _ = p.accept(image: dummyImage(UInt8(i)), sequence: UInt16(i), cameraID: CameraID.left, timestampMicros: 0)
        }
        XCTAssertEqual(p.pendingCount, 1)   // map cleared on overflow; only the newest entry survives
    }

    func testUnknownCameraIDIgnored() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 3, cameraID: 0x00, timestampMicros: 0))
        XCTAssertEqual(p.pendingCount, 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter StereoPairerTests`
Expected: compile failure (`StereoPairer` undefined).

- [ ] **Step 3: Implement `StereoPairer`** in `Sources/XRealVision/StereoCamera.swift`

```swift
public struct StereoPairer {
    public var pendingCount: Int { pending.count }
    public mutating func accept(image: CGImage, sequence: UInt16, cameraID: UInt8,
                                timestampMicros: UInt64) -> StereoFrame?
    public mutating func reset()
}
```

Approach: private `pending: [UInt16: RawEyeFrame]`. In `accept`, ignore any `cameraID` that is neither `CameraID.left` nor `.right`. Insert the new eye; if both eyes now exist for `sequence`, remove the entry and return `StereoFrame(left: 0x20, right: 0x21, sequence, timestampMicros)`; otherwise return nil. If `pending.count > 8` (after insertion), clear the whole map (the spec's overflow rule), then return nil.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter StereoPairerTests`
Expected: all pass.

- [ ] **Step 5: Implement `StereoCamera`** in the same file

```swift
public protocol StereoCameraDelegate: AnyObject {
    func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame)
}
public enum XRealCameraError: Error {
    case deviceNotFound
}
public final class StereoCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var delegate: StereoCameraDelegate?
    public var rawFrameHandler: ((DecodedFrame) -> Void)?
    public static func findXRealDevice() -> AVCaptureDevice?
    public func start() throws
    public func stop()
}
```

Approach (the parts the tests do not determine):
- `findXRealDevice`: `AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices.first { $0.localizedName.contains("UVC Camera") || $0.modelID.contains("VendorID_13080") }`.
- `start()`: if `findXRealDevice()` is nil, `throw XRealCameraError.deviceNotFound`. Build `AVCaptureSession`; add the device as `AVCaptureDeviceInput`; add `AVCaptureVideoDataOutput` with `videoSettings` **never set** (comment why: raw UVC payload must arrive unconverted), `alwaysDiscardsLateVideoFrames = true` (freshness over completeness for a mirror); `setSampleBufferDelegate(self, queue: captureQueue)` on a private serial `DispatchQueue`; `session.startRunning()`.
- `captureOutput` (Swift 6: declare `nonisolated`): skip the first 6 frames via an instance counter guarded by the capture queue (a plain `Int` touched only on that queue, with a comment). For each delivered sample: read the data block via `CMSampleBufferGetDataBuffer` → `CMBlockBufferGetDataLength` → allocate `[UInt8]` of exactly that length → `CMBlockBufferCopyDataBytes`; `XRealFrameDecoder.decode`; on success call `rawFrameHandler` with the `DecodedFrame`, then `makeEyeImage` → `pairer.accept`; on a non-nil pair, call `delegate?.stereoCamera(self, didEmit:)` — all on the capture queue (consumers hop threads).
- `stop()`: `session.stopRunning()` on the capture queue; reset skip counter.
- Concurrency annotations: mark the class `@unchecked Sendable` with the comment "CGImage is immutable; all mutable state is confined to the capture queue." Mark `captureOutput` `nonisolated`.
- Do not attempt to unit-test the AVFoundation session (no mockable seam without cost); it is verified live by Lane 2's probe.

- [ ] **Step 6: Verify the whole package**

Run: `swift test` then `swift build -c release`
Expected: all tests pass (don't assert a total count — the suite is shared), both builds green.

- [ ] **Step 7: Commit**

```bash
git add Sources/XRealVision/StereoCamera.swift Tests/XRealVisionTests/StereoPairerTests.swift
git commit -m "feat: stereo pairing state machine and AVFoundation capture wrapper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Lane completion

When all four tasks are committed: `swift test` green, `swift build -c release` green, and report back with: tasks completed, test coverage summary (which behaviors each test class pins), and any deviations from this plan or the spec (each deviation is a report, not a license — none were needed if all steps passed as written).
