import XCTest
import simd
@testable import XRealMirrorApp

/// Re-fits the left→right camera transform for a specific pair of glasses from markers of known size seen by both eyes.
final class StereoSelfCalibrationTests: XCTestCase {
    let reference = StereoCalibration.xrealAir2Ultra

    /// A "true" calibration that differs from the reference like a different unit might: baseline 8 % longer,
    /// 2° extra rotation.
    private var truth: StereoCalibration {
        let extra = simd_double3x3(simd_quatd(angle: 2 * .pi / 180, axis: simd_normalize(SIMD3(0.2, 1, 0.1))))
        return StereoCalibration(left: reference.left, right: reference.right, rotation: extra * reference.rotation,
                                 translation: reference.translation * 1.08)
    }

    /// Markers at random poses in front of the glasses, projected with `cal` (+ seeded pixel noise).
    private func observations(_ cal: StereoCalibration, count: Int, noisePx: Double, seed: UInt64) -> [StereoSelfCalibration.Observation] {
        var rng = SplitMix64(state: seed), out: [StereoSelfCalibration.Observation] = []
        while out.count < count {
            let c = SIMD3(rng.uniform(-0.15...0.25), rng.uniform(-0.1...0.25), rng.uniform(0.22...0.6))
            let n = simd_normalize(-c + 0.4 * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()))   // roughly facing us
            var right = simd_normalize(simd_cross(SIMD3(0, 1, 0), n)); if rng.uniform(0...1) < 0.5 { right = -right }
            let down = simd_cross(n, right)                         // right × down = −n → face = n
            let r = simd_double3x3(columns: (right, down, simd_cross(right, down)))
            let pts = MarkerPoseEstimator.localCorners().map { r * $0 + c }
            let l = pts.map { cal.left.project($0) }, rr = pts.map { cal.right.project(cal.leftToRight($0)) }
            guard l.allSatisfy({ $0 != nil && (0...479).contains($0!.x) && (0...639).contains($0!.y) }),
                  rr.allSatisfy({ $0 != nil && (0...479).contains($0!.x) && (0...639).contains($0!.y) }) else { continue }
            func noisy(_ p: SIMD2<Double>?) -> SIMD2<Double> { p! + noisePx * SIMD2(rng.gaussian(), rng.gaussian()) }
            out.append(.init(id: 7, left: l.map(noisy), right: rr.map(noisy)))
        }
        return out
    }

    func testRecoversADifferentUnitsExtrinsicsFromNoisyMarkers() throws {
        let obs = observations(truth, count: 150, noisePx: 0.5, seed: 1)
        let fit = try XCTUnwrap(StereoSelfCalibration.fit(obs, start: reference))
        let baselineTruth = simd_length(truth.rightCenterInLeft), baselineFit = simd_length(fit.calibration.rightCenterInLeft)
        let rel = fit.calibration.rotation.transpose * truth.rotation
        let angle = acos(max(-1, min(1, (rel.columns.0.x + rel.columns.1.y + rel.columns.2.z - 1) / 2))) * 180 / .pi
        print(String(format: "[self-cal] synthetic: baseline truth %.2f mm fit %.2f mm (start %.2f), rotation error %.3f°, rms %.2f → %.2f px",
                     baselineTruth * 1000, baselineFit * 1000, simd_length(reference.rightCenterInLeft) * 1000, angle,
                     fit.rmsBefore, fit.rmsAfter))
        XCTAssertEqual(baselineFit / baselineTruth, 1, accuracy: 0.01, "baseline within 1 %")
        XCTAssertLessThan(angle, 0.2)
        XCTAssertLessThan(fit.rmsAfter, 0.8, "residual ≈ the 0.5 px noise")
        XCTAssertGreaterThan(fit.rmsBefore, fit.rmsAfter * 2, "the reference really was wrong for this unit")
    }

    /// Few marker locations alone can't pin all 6 extrinsic DoF (vertical shift trades off against tilt — seen on the
    /// real still capture: a 2 cm vertical offset that made hand triangulation worse). Matched points spread over the
    /// image (hand joints) fix the epipolar geometry; the markers still fix the scale.
    func testMarkersFromOneSpotPlusSpreadPointsPinAllSixDoF() throws {
        // Markers only near ONE spot (like a still guitar) …
        var rng = SplitMix64(state: 9)
        let few = observations(truth, count: 120, noisePx: 1.0, seed: 4).filter { o in
            let c = o.left.reduce(.zero, +) / 4; return c.x > 300 && c.y > 380
        }
        XCTAssertGreaterThan(few.count, 5)
        // … plus 600 matched points anywhere in view (like hand joints), 2 px noise.
        var pts: [StereoSelfCalibration.PointPair] = []
        while pts.count < 600 {
            let p = SIMD3(rng.uniform(-0.25...0.35), rng.uniform(-0.15...0.35), rng.uniform(0.2...0.7))
            guard let l = truth.left.project(p), let r = truth.right.project(truth.leftToRight(p)),
                  (0...479).contains(l.x), (0...639).contains(l.y), (0...479).contains(r.x), (0...639).contains(r.y) else { continue }
            pts.append(.init(left: l + 2 * SIMD2(rng.gaussian(), rng.gaussian()), right: r + 2 * SIMD2(rng.gaussian(), rng.gaussian())))
        }
        let fit = try XCTUnwrap(StereoSelfCalibration.fit(few, points: pts, start: reference))
        let off = fit.calibration.rightCenterInLeft - truth.rightCenterInLeft
        let rel = fit.calibration.rotation.transpose * truth.rotation
        let angle = acos(max(-1, min(1, (rel.columns.0.x + rel.columns.1.y + rel.columns.2.z - 1) / 2))) * 180 / .pi
        print(String(format: "[self-cal] one-spot markers (%d) + 600 points: right-camera position error (%.1f, %.1f, %.1f) mm, rotation %.3f°",
                     few.count, off.x * 1000, off.y * 1000, off.z * 1000, angle))
        XCTAssertLessThan(simd_length(off), 0.003, "camera position within 3 mm")
        XCTAssertLessThan(angle, 0.3)
    }

    func testAlreadyCorrectCalibrationStaysPut() throws {
        let obs = observations(reference, count: 80, noisePx: 0.3, seed: 2)
        let fit = try XCTUnwrap(StereoSelfCalibration.fit(obs, start: reference))
        XCTAssertLessThan(simd_distance(fit.calibration.rightCenterInLeft, reference.rightCenterInLeft), 0.002)
    }

    func testOutlierViewsAreDropped() throws {
        var obs = observations(truth, count: 100, noisePx: 0.3, seed: 3)
        for i in stride(from: 0, to: 100, by: 10) { obs[i].right = obs[i].right.map { $0 + SIMD2(25, -10) } }   // 10 mismatched
        let fit = try XCTUnwrap(StereoSelfCalibration.fit(obs, start: reference))
        XCTAssertEqual(simd_length(fit.calibration.rightCenterInLeft) / simd_length(truth.rightCenterInLeft), 1, accuracy: 0.015)
        XCTAssertLessThanOrEqual(fit.observationsUsed, 92)
    }
}
