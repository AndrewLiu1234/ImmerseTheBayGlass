import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 3: 3-D marker pose from detected corners (stereo, or one eye + known 60 mm).
/// Ground truth = the synthetic fixtures (truth.json), so this needs no glasses and no detector.
final class MarkerPoseTests: XCTestCase {
    let estimator = MarkerPoseEstimator(calibration: .xrealAir2Ultra)

    /// Truth corners → contract observations (normalized, top-left origin; OpenCV px → (px + 0.5) / size), with
    /// optional seeded Gaussian pixel noise like a real detector.
    private func observations(_ truths: [FixturePair.EyeTruth], noisePx: Double = 0, seed: UInt64 = 1,
                              only ids: Set<Int>? = nil) -> [MarkerObservation] {
        var rng = SplitMix64(state: seed)
        return truths.filter { $0.visible && (ids?.contains($0.id) ?? true) }.map { t in
            MarkerObservation(id: t.id, corners: t.cornersPx.map { p in
                let q = p + noisePx * SIMD2(rng.gaussian(), rng.gaussian())
                return SIMD2(Float((q.x + 0.5) / 480), Float((q.y + 0.5) / 640))
            }, hammingDistance: 0)
        }
    }

    private func angleDeg(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        let r = a.transpose * b
        return acos(max(-1, min(1, (r.columns.0.x + r.columns.1.y + r.columns.2.z - 1) / 2))) * 180 / .pi
    }

    private func truthRotation(_ m: MarkerPlacement) -> simd_double3x3 {
        simd_double3x3(columns: (m.right, m.down, simd_cross(m.right, m.down)))
    }

    private struct Errors { var pos: [Double] = []; var ang: [Double] = []; var side: [Double] = [] }

    private func run(noisePx: Double, maxIncidence: Double, eyes: String) throws -> Errors {
        var e = Errors()
        for p in try MarkerFixtureTests.loadTruth() where p.kind != "clutter" {
            let l = eyes == "right" ? [] : observations(p.left, noisePx: noisePx, seed: UInt64(p.index) * 2 + 1)
            let r = eyes == "left" ? [] : observations(p.right, noisePx: noisePx, seed: UInt64(p.index) * 2 + 2)
            for pose in estimator.estimate(left: l, right: r) {
                let m = try XCTUnwrap(p.markers.first { $0.id == pose.id })
                // Filter by the viewing angle of the eye(s) the pose actually used.
                let incL = p.left.first { $0.id == pose.id }!.incidenceDeg, incR = p.right.first { $0.id == pose.id }!.incidenceDeg
                let inc = pose.source == .leftOnly ? incL : (pose.source == .rightOnly ? incR : max(incL, incR))
                guard inc <= maxIncidence else { continue }
                e.pos.append(simd_distance(pose.center, m.center))
                e.ang.append(angleDeg(pose.rotation, truthRotation(m)))
                if let s = pose.triangulatedSide { e.side.append(abs(s - 0.060)) }
                let seenL = p.left.first { $0.id == pose.id }!.visible, seenR = p.right.first { $0.id == pose.id }!.visible
                switch eyes {
                case "left": XCTAssertEqual(pose.source, .leftOnly)
                case "right": XCTAssertEqual(pose.source, .rightOnly)
                default: if seenL && seenR { XCTAssertEqual(pose.source, .stereo) }
                }
            }
        }
        return e
    }

    private func report(_ label: String, _ e: Errors) {
        func q(_ v: [Double], _ f: Double) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * f))] }
        print(String(format: "[marker-pose] %@: n=%d  pos median %.2f mm p90 %.2f mm  angle median %.2f° p90 %.2f°  |side−60| median %.2f mm",
                     label, e.pos.count, q(e.pos, 0.5) * 1000, q(e.pos, 0.9) * 1000, q(e.ang, 0.5), q(e.ang, 0.9), q(e.side, 0.5) * 1000))
    }

    func testStereoPoseIsExactOnExactCorners() throws {
        let e = try run(noisePx: 0, maxIncidence: 90, eyes: "both")
        report("stereo exact", e)
        XCTAssertGreaterThan(e.pos.count, 30)
        XCTAssertLessThan(e.pos.max()!, 0.0005)
        XCTAssertLessThan(e.ang.max()!, 0.2)
        XCTAssertLessThan(e.side.max()!, 0.0003)
    }

    /// The plan's accuracy targets hold at ≤ 0.15 px corner noise (measured: errors scale ~linearly with noise, and
    /// at 0.3 px the stereo angle/side and single-eye targets are missed). So 0.15 px RMS per axis is the corner
    /// precision Person 1's detector must reach; testReportGrazingViews prints the 0.3 px numbers.
    func testStereoPoseWithDetectorNoise() throws {
        let e = try run(noisePx: 0.15, maxIncidence: 90, eyes: "both")
        report("stereo 0.15 px, all views", e)
        let sorted = e.pos.sorted(), ang = e.ang.sorted()
        XCTAssertLessThan(sorted[sorted.count / 2], 0.002, "median position error < 2 mm")
        XCTAssertLessThan(ang[ang.count / 2], 1.0, "median angle error < 1°")
        XCTAssertLessThan(e.side.sorted()[e.side.count / 2], 0.001, "triangulated side within 1 mm of 60")
    }

    func testSingleEyePoseOnFrontalViews() throws {
        for eye in ["left", "right"] {
            let exact = try run(noisePx: 0, maxIncidence: 60, eyes: eye)
            report("\(eye)-only exact", exact)
            XCTAssertLessThan(exact.pos.max()!, 0.0005)
            let noisy = try run(noisePx: 0.15, maxIncidence: 60, eyes: eye)
            report("\(eye)-only 0.15 px (≤60°)", noisy)
            XCTAssertLessThan(noisy.pos.sorted()[noisy.pos.count / 2], 0.005, "median < 5 mm")
            XCTAssertLessThan(noisy.ang.sorted()[noisy.ang.count / 2], 2.0, "median < 2°")
        }
    }

    /// Report-only: the grazing playing-pose views (46–77°) — the hard case the spec flags.
    func testReportGrazingViews() throws {
        report("stereo 0.3 px (≤60°)", try run(noisePx: 0.3, maxIncidence: 60, eyes: "both"))
        report("left-only 0.3 px (≤60°)", try run(noisePx: 0.3, maxIncidence: 60, eyes: "left"))
        report("right-only 0.3 px (≤60°)", try run(noisePx: 0.3, maxIncidence: 60, eyes: "right"))
        report("stereo 0.3 px, all views", try run(noisePx: 0.3, maxIncidence: 90, eyes: "both"))
        report("left-only 0.3 px, all views", try run(noisePx: 0.3, maxIncidence: 90, eyes: "left"))
    }

    func testDifferentMarkersInEachEyeAreNotTriangulated() throws {
        let p = try XCTUnwrap(try MarkerFixtureTests.loadTruth().first { $0.kind == "frontal" })
        let poses = estimator.estimate(left: observations(p.left, only: [7]), right: observations(p.right, only: [8]))
        XCTAssertEqual(Set(poses.map(\.id)), [7, 8])
        XCTAssertEqual(poses.first { $0.id == 7 }?.source, .leftOnly)
        XCTAssertEqual(poses.first { $0.id == 8 }?.source, .rightOnly)
    }

    func testRotationIsProperAndFaceLooksAtTheCamera() throws {
        let p = try XCTUnwrap(try MarkerFixtureTests.loadTruth().first { $0.kind == "frontal" })
        for pose in estimator.estimate(left: observations(p.left), right: observations(p.right)) {
            XCTAssertEqual(simd_determinant(pose.rotation), 1, accuracy: 1e-9)
            XCTAssertLessThan(simd_dot(pose.face, pose.center), 0, "printed face points back toward the glasses")
        }
    }
}
