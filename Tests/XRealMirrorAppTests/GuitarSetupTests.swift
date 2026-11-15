import Foundation
import XCTest
import simd
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 4: one-time guitar setup = still capture (marker poses) + tape → GuitarModel.
final class GuitarSetupTests: XCTestCase {
    private func captures(_ n: Int, posSigma: Double = 0.0005, angSigma: Double = 0.3 * .pi / 180,
                          seed: UInt64 = 42, ids: Set<Int> = [7, 8, 9]) -> [[MarkerPose3D]] {
        var rng = SplitMix64(state: seed)
        return (0..<n).map { _ in
            let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
            return GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, ids: ids,
                                                 posSigma: posSigma, angSigma: angSigma, rng: &rng)
        }
    }

    private func maxCornerError(_ model: GuitarModel) -> Double {
        FixtureGuitar.markers.flatMap { truth -> [Double] in
            let got = model.corners(of: truth.id)!
            return zip(got, truth.corners()).map { simd_distance($0, $1) }
        }.max()!
    }

    func testSetupRecoversTheMarkerMapInTheGuitarFrame() throws {
        let exact = try GuitarSetup.build(captures: captures(10, posSigma: 0, angSigma: 0),
                                          measurements: GuitarTestSupport.exactMeasurements, spec: .yamahaF600)
        XCTAssertLessThan(maxCornerError(exact), 1e-6)
        XCTAssertEqual(exact.scaleCheckError, 0, accuracy: 1e-6)

        let noisy = try GuitarSetup.build(captures: captures(60), measurements: GuitarTestSupport.exactMeasurements,
                                          spec: .yamahaF600)
        print(String(format: "[guitar-setup] 60 noisy captures: max corner error %.2f mm, scale check %+.2f mm, spread %.2f mm",
                     maxCornerError(noisy) * 1000, noisy.scaleCheckError * 1000, noisy.captureSpread * 1000))
        XCTAssertLessThan(maxCornerError(noisy), 0.002)
    }

    func testScaleCheckFlagsWrongTape() throws {
        var tape = GuitarTestSupport.exactMeasurements
        tape.bodyMarkersFret = 13          // off by one fret
        let model = try GuitarSetup.build(captures: captures(10, posSigma: 0, angSigma: 0), measurements: tape, spec: .yamahaF600)
        // The check should report exactly the fret 13 → 14 gap: 634·(2^(−13/12) − 2^(−14/12)) ≈ 16.8 mm.
        let f = Fretboard(spec: .yamahaF600)
        XCTAssertEqual(abs(model.scaleCheckError), f.fretX(14) - f.fretX(13), accuracy: 0.0001)
    }

    func testSetupRejectsInconsistentCaptures() {
        XCTAssertThrowsError(try GuitarSetup.build(captures: captures(30, posSigma: 0.006, angSigma: 0.05),
                                                   measurements: GuitarTestSupport.exactMeasurements, spec: .yamahaF600)) { e in
            guard case GuitarSetup.SetupError.inconsistent = e else { return XCTFail("got \(e)") }
        }
    }

    func testOccasionalBadFramesAreRejectedNotAveraged() throws {
        var caps = captures(40)
        for i in stride(from: 0, to: 40, by: 7) {          // every 7th frame: marker 9 mis-detected 2 cm off
            caps[i] = caps[i].map { var p = $0; if p.id == 9 { p.center += SIMD3(0.02, 0, 0) }; return p }
        }
        let model = try GuitarSetup.build(captures: caps, measurements: GuitarTestSupport.exactMeasurements, spec: .yamahaF600)
        XCTAssertLessThan(maxCornerError(model), 0.002)
    }

    func testMissingMarkerThrows() {
        XCTAssertThrowsError(try GuitarSetup.build(captures: captures(20, ids: [7, 8]),
                                                   measurements: GuitarTestSupport.exactMeasurements, spec: .yamahaF600)) { e in
            guard case GuitarSetup.SetupError.markerNotSeen(9) = e else { return XCTFail("got \(e)") }
        }
    }

    func testSwappedBodyMarkersAreDetected() {
        // If ID 7 and ID 8 were taped on the opposite sides, +y would point to the bass side: refuse.
        let swapped = captures(10, posSigma: 0, angSigma: 0).map { frame in
            frame.map { p -> MarkerPose3D in var p = p; p.id = p.id == 7 ? 8 : (p.id == 8 ? 7 : p.id); return p }
        }
        XCTAssertThrowsError(try GuitarSetup.build(captures: swapped, measurements: GuitarTestSupport.exactMeasurements,
                                                   spec: .yamahaF600)) { e in
            guard case GuitarSetup.SetupError.bodyMarkersSwapped = e else { return XCTFail("got \(e)") }
        }
    }

    func testModelJSONRoundTrip() throws {
        let model = try GuitarSetup.build(captures: captures(10), measurements: GuitarTestSupport.exactMeasurements,
                                          spec: .yamahaF600)
        let back = try JSONDecoder().decode(GuitarModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(back, model)
    }
}

final class GuitarSetupStereoPreferenceTests: XCTestCase {
    /// Noisy single-eye poses must not spoil the map when enough stereo poses exist.
    func testSingleEyePosesAreIgnoredWhenStereoSuffices() throws {
        var rng = SplitMix64(state: 77)
        var caps: [[MarkerPose3D]] = []
        for k in 0..<30 {
            let (r, t) = GuitarTestSupport.randomGuitarPose(&rng)
            var f = GuitarTestSupport.markerPoses(guitarRotation: r, translation: t, posSigma: 0.0005, angSigma: 0.005, rng: &rng)
            if k % 2 == 0 {   // every other frame: an extra, badly-off single-eye ID 9 instead of the stereo one
                f = f.map { var p = $0; if p.id == 9 { p.source = .leftOnly; p.center += SIMD3(0, 0, 0.02 * rng.gaussian()) }; return p }
            }
            caps.append(f)
        }
        let model = try GuitarSetup.build(captures: caps, measurements: GuitarTestSupport.exactMeasurements, spec: .yamahaF600)
        let truth9 = FixtureGuitar.markers.first { $0.id == 9 }!.corners()
        let err = zip(model.corners(of: 9)!, truth9).map { simd_distance($0, $1) }.max()!
        XCTAssertLessThan(err, 0.002)
    }
}
