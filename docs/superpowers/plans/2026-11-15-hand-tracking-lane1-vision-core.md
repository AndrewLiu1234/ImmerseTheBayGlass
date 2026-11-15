# Hand Tracking — Lane 1 (Vision Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `XRealVision` library grows a `StereoHandTracker`: 480×640 gray stereo pairs in, `StereoHands`
(21-landmark hand skeletons per eye, normalized top-left) out at 30fps — fully unit-tested without the glasses,
driven by Apple Vision behind a swappable `HandDetecting` seam.

**Architecture:** Pure contract types + canonical joint constants (Task 1); a pure observation mapper plus the
Vision detector wrapper and gray→RGB conversion (Task 2); the decimating, latest-wins, non-blocking tracker
state machine (Task 3); a benchmark smoke test that times the real detector (Task 4). The stage-1
`StereoCamera`/`StereoPairer`/`FrameLayout` are consumed frozen, never modified.

**Tech Stack:** Swift 6.3 (language mode 6), SwiftPM, XCTest, Vision, Accelerate (vImage), CoreGraphics.

**Spec:** `docs/superpowers/specs/2026-11-15-hand-tracking-design.md` — the interface contract, joint order,
and hazards in it are authoritative. Read it first. (The superseded stereo doc is history, not authority.)

## Global Constraints

- Code against the spec's Interface contract exactly — those names and signatures are what Lane 2 (App) compiles
  against. Do not rename or re-signature anything without stopping and reporting.
- TDD strictly: for every behavior, write the failing test, watch it fail, then implement. No implementation
  without a red test first.
- Own only `Sources/XRealVision/**` and `Tests/XRealVisionTests/**`. Never touch Lane 2's paths
  (`Sources/XRealMirrorApp/**`, `Sources/XRealProbe/**`, `Resources/**`, `scripts/**`, `README.md`, `CLAUDE.md`)
  or `Package.swift` / `.gitignore`. The `Tests/XRealMirrorAppTests` target already exists (coordinator added
  it) — leave it to Lane 2. If a change seems to need another lane, stop and report.
- Never commit a tree that does not build: every task's final verification is `swift build` green plus
  `swift test` green. Lane 2 builds the whole package at any time.
- Swift 6 concurrency: `CGImage` is immutable but not `Sendable`. `StereoHandTracker` is
  `@unchecked Sendable` with a one-line comment ("pending slot behind NSLock, detection confined to the serial
  queue, CGImage payloads immutable"); the `HandDetecting` protocol is NOT `Sendable` — the comment explains it
  is called only on the tracker's queue.
- Zero third-party dependencies. Vision and Accelerate are system frameworks; `import Vision` in the target
  needs no Package.swift entry.
- Hardware facts come only from `FrameLayout` / the spec. The spec's hazard list is binding: y-flip (bottom-left
  → top-left), canonical joint order, decimation by pair counter (never sequence parity — sequence steps 256
  per pair).
- Work on `main` in the shared working tree; commit per task; if `git` reports `index.lock`, wait and retry.
  End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

These are the five ways this lane most plausibly ships a wrong skeleton; each has a pinned test named below.

1. Upside-down skeleton — y-flip skipped (Vision's origin is bottom-left) → `testMapperFlipsY` (Task 2).
2. Scrambled skeleton — joint order or Vision-name mapping wrong (`thumbMP`/`little*` naming traps) →
   `testMapperFullOrderFixture` + `testVisionJointNamesMatchCanonicalOrder` (Task 2).
3. Tracker at the wrong rate — decimation by sequence parity instead of pair count (sequence steps 256) →
   `testDecimationProcessesEveryOtherPair` (Task 3).
4. Stale-frame backlog — a slow frame queues newer frames behind it → `testLatestWinsDropsMiddleFrame` and
   `testAcceptReturnsWhileDetectorBlocked` (Task 3).
5. Detector catastrophically slow on this machine (a gross regression, not a flaky micro-budget) →
   `testDetectorSmokeBudget` (Task 4).

## File Map

- Create: `Sources/XRealVision/HandPose.swift`, `Sources/XRealVision/VisionHandDetector.swift`,
  `Sources/XRealVision/StereoHandTracker.swift`
- Test: `Tests/XRealVisionTests/HandPoseTests.swift`, `Tests/XRealVisionTests/VisionHandDetectorTests.swift`,
  `Tests/XRealVisionTests/StereoHandTrackerTests.swift`, `Tests/XRealVisionTests/HandTrackingBenchmarkTests.swift`

---

### Task 1: Contract types + canonical joint constants

**Files:**
- Create: `Sources/XRealVision/HandPose.swift`
- Test: `Tests/XRealVisionTests/HandPoseTests.swift`

**Interfaces:**
- Produces (Tasks 2–3 here and Lane 2 compile against these): `HandChirality`, `TrackedHand`, `EyeHands`,
  `StereoHands`, `HandJoint`, `HandConnection`, `HandSkeleton` — exact shapes in the spec contract.
  (`StereoHandTrackerDelegate` lands in Task 3 with the tracker class — the protocol references the class,
  so they ship together to keep every commit green.)

- [ ] **Step 1: Write the failing tests** in `Tests/XRealVisionTests/HandPoseTests.swift`:

```swift
import XCTest
import simd
@testable import XRealVision

final class HandPoseTests: XCTestCase {
    func testHandJointCanonicalOrder() {
        XCTAssertEqual(HandJoint.allCases, [
            .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip,
        ])
        XCTAssertEqual(HandJoint.allCases.map(\.rawValue), Array(0..<21))
    }

    func testHandConnectionsMatchCanonical() {
        XCTAssertEqual(HandSkeleton.connections, [
            HandConnection(from: 0, to: 1),  HandConnection(from: 1, to: 2),
            HandConnection(from: 2, to: 3),  HandConnection(from: 3, to: 4),
            HandConnection(from: 0, to: 5),  HandConnection(from: 5, to: 6),
            HandConnection(from: 6, to: 7),  HandConnection(from: 7, to: 8),
            HandConnection(from: 5, to: 9),  HandConnection(from: 9, to: 10),
            HandConnection(from: 10, to: 11), HandConnection(from: 11, to: 12),
            HandConnection(from: 9, to: 13), HandConnection(from: 13, to: 14),
            HandConnection(from: 14, to: 15), HandConnection(from: 15, to: 16),
            HandConnection(from: 13, to: 17), HandConnection(from: 17, to: 18),
            HandConnection(from: 18, to: 19), HandConnection(from: 19, to: 20),
            HandConnection(from: 0, to: 17),
        ])
    }

    func testTrackedHandCountInvariants() {
        let h = TrackedHand(landmarks: [SIMD2<Float>](repeating: .zero, count: 21),
                            confidences: [Float](repeating: 1, count: 21),
                            chirality: .right)
        XCTAssertEqual(h.landmarks.count, 21)
        XCTAssertEqual(h.confidences.count, 21)
    }

    func testEyeHandsEmptyByDefault() {
        XCTAssertTrue(EyeHands().hands.isEmpty)
        XCTAssertTrue(StereoHands(leftEye: EyeHands(), rightEye: EyeHands(),
                                  sequence: 0, timestampMicros: 0).leftEye.hands.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HandPoseTests`
Expected: compile failure (`HandJoint` etc. undefined).

- [ ] **Step 3: Implement in `Sources/XRealVision/HandPose.swift`**

Declare, in the spec's exact shapes:

```swift
public enum HandChirality: Sendable { case left, right, unknown }

public struct TrackedHand: Sendable {
    public var landmarks: [SIMD2<Float>]   // 21, canonical order, normalized 0...1, origin top-left
    public var confidences: [Float]        // 21, same order
    public var chirality: HandChirality
    public init(landmarks: [SIMD2<Float>], confidences: [Float], chirality: HandChirality)
}

public struct EyeHands: Sendable {
    public var hands: [TrackedHand]
    public init(hands: [TrackedHand] = [])
}

public struct StereoHands: Sendable {
    public var leftEye: EyeHands
    public var rightEye: EyeHands
    public var sequence: UInt16
    public var timestampMicros: UInt64
}

public enum HandJoint: Int, CaseIterable, Sendable { /* 21 cases in canonical order, rawValue = index */ }
public struct HandConnection: Equatable, Sendable { public let from: Int; public let to: Int }
public enum HandSkeleton { public static let connections: [HandConnection] }
```

The connections list is the 21 pairs in the test, as the constant. No delegate, no tracker class here —
Task 1 must build green on its own.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HandPoseTests` then `swift build`
Expected: all pass, build green. (Do not assert a total test count — the suite is shared and grows.)

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/HandPose.swift Tests/XRealVisionTests/HandPoseTests.swift
git commit -m "feat: hand-pose contract types and canonical 21-joint skeleton constants

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Gray→RGB + Vision detector + observation mapper

**Files:**
- Create: `Sources/XRealVision/VisionHandDetector.swift`
- Test: `Tests/XRealVisionTests/VisionHandDetectorTests.swift`

**Interfaces:**
- Consumes: `FrameLayout` (stage 1), `TrackedHand`, `HandChirality`, `HandJoint` (Task 1).
- Produces (Task 3 and Lane 2 rely on): `GrayToRGB` (byte-array core **and** a CGImage convenience),
  `RawHandObservation`, `HandObservationMapper`, `HandDetecting` protocol, `VisionHandDetector`.

- [ ] **Step 1: Write the failing tests** in `Tests/XRealVisionTests/VisionHandDetectorTests.swift`:

```swift
import XCTest
import CoreGraphics
import simd
@testable import XRealVision

final class VisionHandDetectorTests: XCTestCase {
    // Gray→RGB: single-value gray must replicate into all three channels, geometry preserved.
    private func pixelAt(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let d = img.dataProvider!.data! as Data
        let row = img.bytesPerRow
        let o = y * row + x * 3
        return (d[o], d[o + 1], d[o + 2])
    }

    func testGrayToRGBReplicatesChannels() {
        var gray = [UInt8](repeating: 0x40, count: 480 * 640)
        gray[100 * 480 + 200] = 0xAB   // row 100, col 200
        guard let rgb = GrayToRGB.convert(upright: gray, width: 480, height: 640) else {
            return XCTFail("convert returned nil")
        }
        XCTAssertEqual(rgb.width, 480)
        XCTAssertEqual(rgb.height, 640)
        XCTAssertEqual(rgb.bitsPerPixel, 24)
        XCTAssertEqual(pixelAt(rgb, 200, 100).0, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 200, 100).1, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 200, 100).2, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 0, 0).0, 0x40)
    }

    // Mapper: y-flip. Vision origin is bottom-left; contract is top-left.
    func testMapperFlipsY() {
        let raw = RawHandObservation(points: [SIMD2<Float>](repeating: .zero, count: 21),
                                     chirality: .left)
        var flipped = raw
        flipped.points[0] = SIMD2<Float>(0.5, 0.25)
        let hand = HandObservationMapper.map(flipped)
        XCTAssertEqual(hand.landmarks[0].x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(hand.landmarks[0].y, 0.75, accuracy: 1e-6)   // 1 − 0.25
        XCTAssertEqual(hand.chirality, .left)
    }

    // Mapper: a full 21-joint fixture must come out in canonical order with confidences preserved.
    func testMapperFullOrderFixture() {
        var points = [SIMD2<Float>?](repeating: nil, count: 21)
        for i in 0..<21 {
            points[i] = SIMD2<Float>(Float(i) / 21.0, Float(20 - i) / 21.0)
        }
        let raw = RawHandObservation(points: points, confidences: (0..<21).map { Float($0) / 21.0 },
                                     chirality: .right)
        let hand = HandObservationMapper.map(raw)
        for i in 0..<21 {
            XCTAssertEqual(hand.landmarks[i].x, Float(i) / 21.0, accuracy: 1e-6, "joint \(i)")
            XCTAssertEqual(hand.landmarks[i].y, Float(i) / 21.0, accuracy: 1e-6, "joint \(i) y-flipped")
            XCTAssertEqual(hand.confidences[i], Float(i) / 21.0, accuracy: 1e-6, "joint \(i) conf")
        }
    }

    // Mapper: missing joints degrade to origin + zero confidence, never crash or reorder.
    func testMapperMissingJointsBecomeZeroConfidenceOrigin() {
        var points = [SIMD2<Float>?](repeating: nil, count: 21)
        points[8] = SIMD2<Float>(0.4, 0.6)
        let hand = HandObservationMapper.map(RawHandObservation(points: points, chirality: .unknown))
        XCTAssertEqual(hand.landmarks[8].x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(hand.confidences[8], 1.0, accuracy: 1e-6)
        XCTAssertEqual(hand.landmarks[0], .zero)
        XCTAssertEqual(hand.confidences[0], 0.0)
    }

    // The Vision-name table, in canonical order — the mapping's single source of truth.
    func testVisionJointNamesMatchCanonicalOrder() {
        XCTAssertEqual(VisionHandDetector.jointNames, [
            .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip,
        ])
    }

    // The convenience wrapper must agree with the core — production uses the wrapper (frames are CGImages).
    func testGrayToRGBFromCGImageMatchesCore() {
        var gray = [UInt8](repeating: 0x20, count: 480 * 640)
        gray[640 * 480 / 2 + 240] = 0xEE
        let grayImage = XRealFrameDecoder.makeCGImage(upright: gray)!
        let rgb = GrayToRGB.convert(image: grayImage)!
        XCTAssertEqual(rgb.width, 480)
        XCTAssertEqual(rgb.bitsPerPixel, 24)
        XCTAssertEqual(pixelAt(rgb, 240, 320).0, 0xEE)
        XCTAssertEqual(pixelAt(rgb, 240, 320).1, 0xEE)
        XCTAssertEqual(pixelAt(rgb, 240, 320).2, 0xEE)
    }

    // Real Vision on a synthetic frame: no hand → empty result, and it must not throw or hang.
    func testDetectorReturnsEmptyOnBlankFrame() throws {
        let gray = [UInt8](repeating: 0x20, count: 480 * 640)
        let rgb = GrayToRGB.convert(upright: gray, width: 480, height: 640)!
        let result = try VisionHandDetector().detectHands(in: rgb)
        XCTAssertTrue(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VisionHandDetectorTests`
Expected: compile failure (`GrayToRGB`, mapper, detector undefined).

- [ ] **Step 3: Implement in `Sources/XRealVision/VisionHandDetector.swift`**

```swift
public enum GrayToRGB {
    public static func convert(upright: [UInt8], width: Int, height: Int) -> CGImage?
    // vImageConvert_Planar8toRGB888: same planar source for all three channels, one call,
    // caller-provided buffer; return nil on wrong input count.
    public static func convert(image: CGImage) -> CGImage?
    // Thin wrapper: read dataProvider bytes, delegate to convert(upright:width:height:).
    // The tracker calls this one — StereoFrame carries CGImages, not byte arrays.
}

internal struct RawHandObservation {
    internal var points: [SIMD2<Float>?]      // 21, Vision-normalized, origin bottom-left
    internal var confidences: [Float?]        // 21
    internal var chirality: HandChirality
    internal init(points: [SIMD2<Float>?], confidences: [Float?]? = nil, chirality: HandChirality)
}

public enum HandObservationMapper {
    public static func map(_ raw: RawHandObservation) -> TrackedHand
    // Iterate HandJoint.allCases in order; take raw.points[rawValue] (nil → (0,0) / 0.0 confidence);
    // a present point whose confidence is nil defaults to 1.0; y' = 1 − y. Chirality passes through.
}

public protocol HandDetecting {
    func detectHands(in image: CGImage) throws -> [TrackedHand]
    // Called only on StereoHandTracker's serial queue; implementations are stateless besides the Vision request.
}

public struct VisionHandDetector: HandDetecting {
    public static let jointNames: [VNHumanHandPoseObservation.JointName]   // canonical order, pinned by the test
    public init()
    public func detectHands(in image: CGImage) throws -> [TrackedHand]
}
```

Approach for `detectHands`: one `VNDetectHumanHandPoseRequest` with `maximumHandCount = 2`, stored on the
struct; `VNImageRequestHandler(cgImage: image)` → `try handler.perform([request])`; for each
`VNHumanHandPoseObservation`: read `recognizedPoints`, build `RawHandObservation` in canonical order via
`jointNames` (missing dictionary keys → nil), chirality from `observation.chirality`
(`VNChirality.left/.right/.unknown` map to `HandChirality`); `HandObservationMapper.map` each.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VisionHandDetectorTests` then `swift build`
Expected: all pass, build green. If `testDetectorReturnsEmptyOnBlankFrame` fails (Vision returns hands on a
flat gray frame, or errors), STOP and report — the pipeline's real-world input assumption is wrong.

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/VisionHandDetector.swift Tests/XRealVisionTests/VisionHandDetectorTests.swift
git commit -m "feat: gray-to-RGB conversion, Vision hand detector, and canonical observation mapper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: StereoHandTracker — decimation, latest-wins, non-blocking accept

**Files:**
- Create: `Sources/XRealVision/StereoHandTracker.swift`
- Test: `Tests/XRealVisionTests/StereoHandTrackerTests.swift`

**Interfaces:**
- Consumes: `StereoFrame`, `FrameLayout` (stage 1), `HandDetecting`, `TrackedHand`, `StereoHands`
  (Tasks 1–2), `GrayToRGB` (Task 2).
- Produces (Lane 2 wires these): `StereoHandTracker` with `init(detector:processEveryNthPair:)`,
  `accept(_:)`, `delegate`, and the `StereoHandTrackerDelegate` protocol — spec contract shapes. The delegate
  protocol ships in this task alongside the class (it references the class, so they land together).

- [ ] **Step 1: Write the failing tests** in `Tests/XRealVisionTests/StereoHandTrackerTests.swift`:

```swift
import XCTest
import CoreGraphics
import simd
@testable import XRealVision

private final class FakeDetector: HandDetecting {
    var results: [TrackedHand] = []
    var gate: DispatchSemaphore? = nil      // when set, each detect blocks until released
    private(set) var callCount = 0
    func detectHands(in image: CGImage) throws -> [TrackedHand] {
        callCount += 1
        gate?.wait()
        return results
    }
}

private final class CollectingDelegate: StereoHandTrackerDelegate {
    // Hold this in a local `let` in the test — tracker.delegate is weak, an inline temp would deallocate.
    var sequences: [UInt16] = []
    let done: XCTestExpectation
    init(_ done: XCTestExpectation) { self.done = done }
    func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands) {
        sequences.append(hands.sequence)
        done.fulfill()   // every emit fulfills; each test sets expectedFulfillmentCount to the exact emit count
    }
}

final class StereoHandTrackerTests: XCTestCase {
    private func frame(_ seq: UInt16) -> StereoFrame {
        let img = XRealFrameDecoder.makeCGImage(upright: [UInt8](repeating: 0x80,
            count: FrameLayout.uprightWidth * FrameLayout.uprightHeight))!
        let left = RawEyeFrame(image: img, cameraID: CameraID.left, sequence: seq, timestampMicros: UInt64(seq))
        let right = RawEyeFrame(image: img, cameraID: CameraID.right, sequence: seq, timestampMicros: UInt64(seq))
        return StereoFrame(left: left, right: right, sequence: seq, timestampMicros: UInt64(seq))
    }

    // Decimation counts ACCEPTED pairs, never sequence parity (sequence steps 256 on hardware).
    func testDecimationProcessesEveryOtherPair() {
        let fake = FakeDetector()
        fake.results = [TrackedHand(landmarks: [SIMD2<Float>](repeating: .zero, count: 21),
                                    confidences: [Float](repeating: 1, count: 21), chirality: .left)]
        let tracker = StereoHandTracker(detector: fake, processEveryNthPair: 2)
        let done = expectation(description: "3 emissions for 5 accepted pairs")
        done.expectedFulfillmentCount = 3
        let delegate = CollectingDelegate(done)
        tracker.delegate = delegate
        for seq in [UInt16(0), 256, 512, 768, 1024] { tracker.accept(frame(seq)) }  // seq steps 256, like hardware
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fake.callCount, 3)                       // accepted pairs 0, 2, 4
    }

    // Latest-wins: the middle pending frame is dropped; the newest one is processed next.
    func testLatestWinsDropsMiddleFrame() {
        let fake = FakeDetector()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let tracker = StereoHandTracker(detector: fake)
        let done = expectation(description: "first then newest, never the middle")
        done.expectedFulfillmentCount = 2
        let delegate = CollectingDelegate(done)
        tracker.delegate = delegate
        tracker.accept(frame(0))    // starts processing, blocked on gate
        tracker.accept(frame(2))    // pending
        tracker.accept(frame(4))    // replaces pending
        gate.signal()               // release first detect
        gate.signal()               // release second detect (the loop then takes the newest pending: seq 4)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(delegate.sequences, [0, 4])
    }

    // Non-blocking: accept returns immediately even while detection is stuck.
    func testAcceptReturnsWhileDetectorBlocked() {
        let fake = FakeDetector()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let tracker = StereoHandTracker(detector: fake)
        let done = expectation(description: "both accepted pairs eventually process")
        done.expectedFulfillmentCount = 2
        let delegate = CollectingDelegate(done)
        tracker.delegate = delegate
        let start = Date()
        tracker.accept(frame(0))
        tracker.accept(frame(2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)   // both accepts returned
        gate.signal(); gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(delegate.sequences, [0, 2])
    }

    // Empty detections still emit, with the frame's sequence/timestamp and empty hands arrays.
    func testEmptyBothEyesEmitsEmptyHands() {
        let fake = FakeDetector()
        let tracker = StereoHandTracker(detector: fake)
        let done = expectation(description: "one emission")
        final class OneShot: StereoHandTrackerDelegate {
            let done: XCTestExpectation
            var hands: StereoHands?
            init(_ d: XCTestExpectation) { done = d }
            func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands) {
                self.hands = hands; done.fulfill()
            }
        }
        let d = OneShot(done)
        tracker.delegate = d
        tracker.accept(frame(42))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(d.hands?.sequence, 42)
        XCTAssertEqual(d.hands?.timestampMicros, 42)
        XCTAssertTrue(d.hands?.leftEye.hands.isEmpty == true)
        XCTAssertTrue(d.hands?.rightEye.hands.isEmpty == true)
    }

    // Detected hands appear on BOTH eyes (the tracker runs the detector once per eye).
    func testPerEyeAggregation() {
        let fake = FakeDetector()
        let hand = TrackedHand(landmarks: [SIMD2<Float>](repeating: .zero, count: 21),
                               confidences: [Float](repeating: 1, count: 21), chirality: .right)
        fake.results = [hand]
        let tracker = StereoHandTracker(detector: fake)
        let done = expectation(description: "one emission")
        final class Grab: StereoHandTrackerDelegate {
            let done: XCTestExpectation
            var hands: StereoHands?
            init(_ d: XCTestExpectation) { done = d }
            func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands) {
                self.hands = hands; done.fulfill()
            }
        }
        let g = Grab(done)
        tracker.delegate = g
        tracker.accept(frame(7))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fake.callCount, 2)                       // left + right
        XCTAssertEqual(g.hands?.leftEye.hands.count, 1)
        XCTAssertEqual(g.hands?.rightEye.hands.count, 1)
        XCTAssertEqual(g.hands?.leftEye.hands[0].chirality, .right)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter StereoHandTrackerTests`
Expected: compile failure (`StereoHandTracker` and `StereoHandTrackerDelegate` undefined — they land in this task).

- [ ] **Step 3: Implement in `Sources/XRealVision/StereoHandTracker.swift`**

```swift
public protocol StereoHandTrackerDelegate: AnyObject {
    func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands)
}

public final class StereoHandTracker: @unchecked Sendable {
    // Sendability: pending slot behind NSLock, detection confined to the serial queue, CGImage payloads
    // immutable (the stage-1 FrameBox pattern).
    public init(detector: any HandDetecting = VisionHandDetector(), processEveryNthPair: Int = 2)
    public weak var delegate: StereoHandTrackerDelegate?
    public func accept(_ frame: StereoFrame)    // non-blocking, O(1)
}
```

Approach (the machinery the tests do not determine):
- `accept`: under the NSLock, read `acceptedCount` as the pair's 0-based index, then increment it; when
  `index % processEveryNthPair == 0`, store the frame in `pending` (replacing any older one) and signal a
  counting `DispatchSemaphore`; never call the detector here. (So accepted pairs 0, 2, 4, … are processed —
  the decimation test pins exactly that.)
- A private serial `DispatchQueue` runs a loop: wait on the semaphore; take the newest `pending` under the lock
  (set it nil); for each eye, `GrayToRGB.convert(image: frame.left.image)` / `frame.right.image` then
  `detector.detectHands`; wrap in `StereoHands` with the frame's `sequence`/`timestampMicros`; call
  `delegate?.stereoHandTracker(self, didTrack:)` on the same queue (Lane 2 hops to main — their job).
- Keep a retainable reference to the queue loop via `DispatchSource` or a semaphore-driven worker; document it
  with a comment. `deinit` must not need queue teardown beyond the process lifetime.
- `processEveryNthPair <= 0` → precondition failure.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter StereoHandTrackerTests` then `swift test` then `swift build`
Expected: all pass, full suite green (Tasks 1–2 tests included), build green.

- [ ] **Step 5: Commit**

```bash
git add Sources/XRealVision/StereoHandTracker.swift Tests/XRealVisionTests/StereoHandTrackerTests.swift
git commit -m "feat: decimating latest-wins stereo hand tracker with non-blocking accept

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Detector benchmark smoke test

**Files:**
- Test: `Tests/XRealVisionTests/HandTrackingBenchmarkTests.swift`

**Interfaces:**
- Consumes: `VisionHandDetector`, `GrayToRGB` (Task 2).

- [ ] **Step 1: Write the failing test** in `Tests/XRealVisionTests/HandTrackingBenchmarkTests.swift`:

```swift
import XCTest
@testable import XRealVision

final class HandTrackingBenchmarkTests: XCTestCase {
    // Smoke bound only: catches a gross regression (e.g. a broken request config), never a micro-budget.
    // The real 15ms/pair budget is verified live on the glasses; CI stays honest with 10x headroom.
    func testDetectorSmokeBudget() throws {
        let rgb = GrayToRGB.convert(upright: [UInt8](repeating: 0x30, count: 480 * 640),
                                    width: 480, height: 640)!
        let detector = VisionHandDetector()
        _ = try detector.detectHands(in: rgb)          // warmup (model load, queue setup)
        var times: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try detector.detectHands(in: rgb)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "[hand-tracking benchmark] median %.2f ms/call, min %.2f, max %.2f (480x640, %d calls)",
                     median, times.min()!, times.max()!, times.count))
        XCTAssertLessThan(median, 100.0)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter HandTrackingBenchmarkTests`
Expected: it passes on first run (Vision is available) — treat "fail" here as the test printing the report and
the smoke bound holding; if the median exceeds 100ms, STOP and report, do not raise the bound.

- [ ] **Step 3: Commit**

```bash
git add Tests/XRealVisionTests/HandTrackingBenchmarkTests.swift
git commit -m "test: hand detector benchmark smoke test (480x640, median < 100ms)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Lane completion

When all four tasks are committed: `swift test` green, `swift build -c release` green, and report back with:
tasks completed, the benchmark report (median ms/call), and any deviations from this plan or the spec (each
deviation is a report, not a license — none were needed if all steps passed as written).
