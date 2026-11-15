import XCTest
import simd
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 5: live guitar pose from whichever markers are visible.
final class GuitarTrackerTests: XCTestCase {
    /// The fixture guitar's true model (what a perfect setup would produce).
    static let model = GuitarModel(
        name: "fixture", spec: .yamahaF600,
        markers: FixtureGuitar.markers.map { GuitarModel.MarkerCorners(id: $0.id, corners: $0.corners()) },
        measurements: GuitarTestSupport.exactMeasurements, scaleCheckError: 0, captureSpread: 0, framesUsed: 0)

    /// Worst error over the fingering points (nut + frets 1–12 on the centre line), camera frame.
    private func fingeringError(_ pose: GuitarPose, _ r: simd_double3x3, _ t: SIMD3<Double>) -> Double {
        GuitarTestSupport.fingeringPoints.map { simd_distance(pose.toCamera($0), r * $0 + t) }.max()!
    }

    func testPoseFromEverySubsetOfMarkers() throws {
        let subsets: [Set<Int>] = [[7, 8, 9], [7, 8], [7, 9], [8, 9], [7], [8], [9]]
        for subset in subsets {
            var rng = SplitMix64(state: 7)
            var exactErr = 0.0, noisy: [Double] = []
            for _ in 0..<50 {
                let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
                var tracker = GuitarTracker(model: Self.model, smoothing: false)
                let exact = try XCTUnwrap(tracker.update(
                    GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, ids: subset, rng: &rng), timestamp: 0))
                exactErr = max(exactErr, fingeringError(exact, r, t))
                let p = try XCTUnwrap(tracker.update(GuitarTestSupport.markerPoses(
                    guitarRotation: r, translation: t, ids: subset, posSigma: 0.0005, angSigma: 0.3 * .pi / 180, rng: &rng),
                    timestamp: 1))
                noisy.append(fingeringError(p, r, t))
                XCTAssertEqual(Set(p.markersUsed), subset)
            }
            noisy.sort()
            let p90 = noisy[noisy.count * 9 / 10]
            print(String(format: "[guitar-tracker] markers %@: exact %.4f mm, noisy (0.5 mm/0.3° per marker) median %.2f mm p90 %.2f mm",
                         subset.sorted().map(String.init).joined(separator: "+"), exactErr * 1000,
                         noisy[noisy.count / 2] * 1000, p90 * 1000))
            XCTAssertLessThan(exactErr, 1e-6)
            // A priori from error propagation: 0.3° over the ≈ 35 cm neck ≈ 1.8 mm, plus 0.5 mm position.
            // What pins the neck's direction is a marker pair spanning the neck — ID 9 (headstock) with 7 or 8.
            // 7+8 sit side by side across the neck at fret 14 (13 cm apart, nothing toward the nut), so the angle
            // along the neck rests on the markers' own tilts exactly as with one marker: measured 7+8 ≈ 7 alone.
            // So: with ID 9 and another marker < 3 mm; otherwise the single-marker bound < 5 mm.
            let spansNeck = subset.contains(9) && subset.count >= 2
            XCTAssertLessThan(p90, spansNeck ? 0.003 : 0.005, "subset \(subset.sorted())")
        }
    }

    func testOutlierMarkerIsIgnored() throws {
        var rng = SplitMix64(state: 3)
        let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
        var markers = GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, rng: &rng)
        markers = markers.map { var m = $0; if m.id == 9 { m.center += SIMD3(0.02, -0.01, 0) }; return m }
        var tracker = GuitarTracker(model: Self.model, smoothing: false)
        let p = try XCTUnwrap(tracker.update(markers, timestamp: 0))
        XCTAssertEqual(Set(p.markersUsed), [7, 8])
        XCTAssertLessThan(fingeringError(p, r, t), 0.0005)
    }

    func testHoldsBrieflyThenReportsLost() throws {
        var rng = SplitMix64(state: 5)
        let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
        var tracker = GuitarTracker(model: Self.model)
        let seen = try XCTUnwrap(tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, rng: &rng), timestamp: 0))
        XCTAssertEqual(seen.state, .tracking)
        let held = try XCTUnwrap(tracker.update([], timestamp: 0.3))
        XCTAssertEqual(held.state, .holding)
        XCTAssertLessThan(simd_distance(held.translation, seen.translation), 1e-12)
        XCTAssertNil(tracker.update([], timestamp: 0.6), "lost after 0.5 s without markers")
        // Reacquire somewhere else: no smoothing lag from the stale pose.
        let (r2, t2) = GuitarTestSupport.randomGuitarPose(&rng)
        let back = try XCTUnwrap(tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r2, translation: t2, rng: &rng), timestamp: 0.7))
        XCTAssertEqual(back.state, .tracking)
        XCTAssertLessThan(fingeringError(back, r2, t2), 1e-6)
    }

    func testSmoothingConvergesAndSettlesWithinHalfASecond() throws {
        var rng = SplitMix64(state: 9)
        let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
        var tracker = GuitarTracker(model: Self.model)
        for i in 0..<30 { _ = tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, rng: &rng), timestamp: Double(i) / 30) }
        // Step: 5 cm sideways and 20° of rotation at once.
        let r2 = simd_double3x3(simd_quatd(angle: 20 * .pi / 180, axis: SIMD3(0, 1, 0))) * r, t2 = t + SIMD3(0.05, 0, 0)
        var last: GuitarPose?
        for i in 30..<45 {   // half a second at 30 fps
            last = tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r2, translation: t2, rng: &rng), timestamp: Double(i) / 30)
        }
        let p = try XCTUnwrap(last)
        XCTAssertLessThan(simd_distance(p.translation, t2), 0.005, "within 10 % of the 5 cm step")
        let angle = acos(max(-1, min(1, ((p.rotation.transpose * r2).columns.0.x + (p.rotation.transpose * r2).columns.1.y
                                         + (p.rotation.transpose * r2).columns.2.z - 1) / 2)))
        XCTAssertLessThan(angle, 2 * .pi / 180, "within 10 % of the 20° step")
        for i in 45..<120 { last = tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r2, translation: t2, rng: &rng), timestamp: Double(i) / 30) }
        XCTAssertLessThan(fingeringError(try XCTUnwrap(last), r2, t2), 0.0001)
    }

    func testFretboardPointsLandWhereTheyShould() throws {
        var rng = SplitMix64(state: 11)
        let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
        var tracker = GuitarTracker(model: Self.model, smoothing: false)
        let p = try XCTUnwrap(tracker.update(GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, rng: &rng), timestamp: 0))
        let twelfth = Fretboard(spec: .yamahaF600).fretLine(12)
        XCTAssertLessThan(simd_distance(p.toCamera(twelfth.0), r * twelfth.0 + t), 1e-6)
        XCTAssertLessThan(simd_distance(p.toGuitar(p.toCamera(SIMD3(0.1, 0.02, 0.003))), SIMD3(0.1, 0.02, 0.003)), 1e-9)
    }
}
