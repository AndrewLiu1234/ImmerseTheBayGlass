import XCTest
import CoreGraphics
import simd
@testable import XRealVision

private final class FakeMarkerDetector: MarkerDetecting {
    var results: [MarkerObservation] = []
    var gate: DispatchSemaphore? = nil      // when set, each detect blocks until released
    private(set) var callCount = 0
    func detectMarkers(in image: CGImage) throws -> [MarkerObservation] {
        callCount += 1
        gate?.wait()
        return results
    }
}

private final class CollectingDelegate: StereoMarkerTrackerDelegate {
    // Hold this in a local `let` in the test — tracker.delegate is weak, an inline temp would deallocate.
    var sequences: [UInt16] = []
    var done: XCTestExpectation?            // fulfilled on EVERY emit while set; tests swap it per step
    func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers) {
        sequences.append(markers.sequence)
        done?.fulfill()
    }
}

final class StereoMarkerTrackerTests: XCTestCase {
    private func frame(_ seq: UInt16) -> StereoFrame {
        let img = XRealFrameDecoder.makeCGImage(upright: [UInt8](repeating: 0x80,
            count: FrameLayout.uprightWidth * FrameLayout.uprightHeight))!
        let left = RawEyeFrame(image: img, cameraID: CameraID.left, sequence: seq, timestampMicros: UInt64(seq))
        let right = RawEyeFrame(image: img, cameraID: CameraID.right, sequence: seq, timestampMicros: UInt64(seq))
        return StereoFrame(left: left, right: right, sequence: seq, timestampMicros: UInt64(seq))
    }

    /// Polls with the run loop so the tracker's queue gets CPU until `cond` holds.
    private func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(cond(), "condition not met within \(timeout)s")
    }

    private func marker(_ id: Int) -> MarkerObservation {
        MarkerObservation(id: id,
                          corners: [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)],
                          hammingDistance: 0)
    }

    // Decimation counts ACCEPTED pairs, never sequence parity (sequence steps 256 on hardware).
    // Handshake pacing keeps the worker caught up — the condition the spec's rule is defined under.
    // NOTE: the gate blocks every EYE detect, so each pair needs TWO releases.
    func testDecimationProcessesEveryOtherPair() {
        let fake = FakeMarkerDetector()
        fake.results = [marker(7)]
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let tracker = StereoMarkerTracker(detector: fake, processEveryNthPair: 2)
        let delegate = CollectingDelegate()
        tracker.delegate = delegate

        tracker.accept(frame(0))          // idx 0 → worker takes it, both eye detects block on gate
        delegate.done = expectation(description: "emit 1")
        gate.signal(); gate.signal()      // release both eyes → emit 0
        wait(for: [delegate.done!], timeout: 5)

        tracker.accept(frame(256))        // idx 1 → decimated away
        tracker.accept(frame(512))        // idx 2 → worker takes it, blocks on gate
        delegate.done = expectation(description: "emit 2")
        gate.signal(); gate.signal()      // → emit 512
        wait(for: [delegate.done!], timeout: 5)

        tracker.accept(frame(768))        // idx 3 → decimated away
        tracker.accept(frame(1024))       // idx 4 → worker takes it, blocks on gate
        delegate.done = expectation(description: "emit 3")
        gate.signal(); gate.signal()      // → emit 1024
        wait(for: [delegate.done!], timeout: 5)

        XCTAssertEqual(fake.callCount, 6)                 // 3 pairs × 2 eyes
        XCTAssertEqual(delegate.sequences, [0, 512, 1024])
    }

    // Latest-wins: seq 512 sits in `pending` while the worker is busy with seq 0; seq 1024
    // REPLACES it — the spec's "newer replaces older" rule, pinned deterministically.
    func testLatestWinsDropsMiddleFrame() {
        let fake = FakeMarkerDetector()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let tracker = StereoMarkerTracker(detector: fake)
        let delegate = CollectingDelegate()
        tracker.delegate = delegate

        tracker.accept(frame(0))          // idx 0
        waitUntil { fake.callCount == 1 } // worker has TAKEN seq 0: eye L blocked on gate
        tracker.accept(frame(256))        // idx 1 → decimated away
        tracker.accept(frame(512))        // idx 2 → pending (worker busy)
        tracker.accept(frame(768))        // idx 3 → decimated away
        tracker.accept(frame(1024))       // idx 4 → REPLACES pending (latest wins)

        delegate.done = expectation(description: "emit 0 then 1024")
        delegate.done?.expectedFulfillmentCount = 2
        gate.signal(); gate.signal()      // pair 0's two eyes → emit 0
        gate.signal(); gate.signal()      // worker drains → takes 1024 → its two eyes → emit 1024
        wait(for: [delegate.done!], timeout: 5)
        XCTAssertEqual(fake.callCount, 4)                 // 2 pairs × 2 eyes
        XCTAssertEqual(delegate.sequences, [0, 1024])
    }

    // Non-blocking: accept returns immediately even while detection is stuck.
    func testAcceptReturnsWhileDetectorBlocked() {
        let fake = FakeMarkerDetector()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let tracker = StereoMarkerTracker(detector: fake)
        let delegate = CollectingDelegate()
        tracker.delegate = delegate

        tracker.accept(frame(0))          // idx 0
        waitUntil { fake.callCount == 1 } // worker blocked in eye-L detect
        let start = Date()
        tracker.accept(frame(256))        // idx 1 → decimated away
        tracker.accept(frame(512))        // idx 2 → pending
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)   // accepts returned while detect stuck

        delegate.done = expectation(description: "emit 0 then 512")
        delegate.done?.expectedFulfillmentCount = 2
        gate.signal(); gate.signal()      // pair 0
        gate.signal(); gate.signal()      // pair 512
        wait(for: [delegate.done!], timeout: 5)
        XCTAssertEqual(delegate.sequences, [0, 512])
    }

    // Empty detections still emit, with the frame's sequence/timestamp and empty marker arrays.
    func testEmptyBothEyesEmitsEmptyMarkers() {
        let fake = FakeMarkerDetector()
        let tracker = StereoMarkerTracker(detector: fake)
        let done = expectation(description: "one emission")
        final class OneShot: StereoMarkerTrackerDelegate {
            let done: XCTestExpectation
            var markers: StereoMarkers?
            init(_ d: XCTestExpectation) { done = d }
            func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers) {
                self.markers = markers; done.fulfill()
            }
        }
        let d = OneShot(done)
        tracker.delegate = d
        tracker.accept(frame(42))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(d.markers?.sequence, 42)
        XCTAssertEqual(d.markers?.timestampMicros, 42)
        XCTAssertTrue(d.markers?.leftEye.markers.isEmpty == true)
        XCTAssertTrue(d.markers?.rightEye.markers.isEmpty == true)
    }

    // Detected markers appear on BOTH eyes (the tracker runs the detector once per eye).
    func testPerEyeAggregation() {
        let fake = FakeMarkerDetector()
        fake.results = [marker(8)]
        let tracker = StereoMarkerTracker(detector: fake)
        let done = expectation(description: "one emission")
        final class Grab: StereoMarkerTrackerDelegate {
            let done: XCTestExpectation
            var markers: StereoMarkers?
            init(_ d: XCTestExpectation) { done = d }
            func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers) {
                self.markers = markers; done.fulfill()
            }
        }
        let g = Grab(done)
        tracker.delegate = g
        tracker.accept(frame(7))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fake.callCount, 2)                       // left + right
        XCTAssertEqual(g.markers?.leftEye.markers.count, 1)
        XCTAssertEqual(g.markers?.rightEye.markers.count, 1)
        XCTAssertEqual(g.markers?.leftEye.markers[0].id, 8)
    }
}
