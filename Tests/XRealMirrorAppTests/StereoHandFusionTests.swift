import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

final class StereoHandFusionTests: XCTestCase {
    let cal = StereoCalibration.xrealAir2Ultra

    /// A plausible open hand (21 joints, canonical order) around `wrist`, fingers pointing up (-y), in metres.
    private func hand3D(wrist: SIMD3<Double>) -> [SIMD3<Double>] {
        var j = [SIMD3<Double>](repeating: wrist, count: 21)
        let fingerX: [Double] = [-0.035, -0.02, 0.0, 0.02, 0.035]   // thumb, index, middle, ring, little
        for f in 0..<5 {
            for k in 0..<4 {
                let up = 0.03 + 0.022 * Double(k) - (f == 0 ? 0.015 : 0)
                j[1 + f * 4 + k] = wrist + SIMD3(fingerX[f] * (1 + 0.3 * Double(k)), -up, 0.004 * Double(k))
            }
        }
        return j
    }

    /// What the tracker would report for `joints` in one eye (normalized, top-left origin).
    /// `noisePx` jitters each joint deterministically by up to that many pixels, like real detections.
    private func tracked(_ joints: [SIMD3<Double>], rightEye: Bool, chirality: HandChirality = .right,
                         noisePx: Double = 0) throws -> TrackedHand {
        let pts = try joints.enumerated().map { i, p -> SIMD2<Float> in
            var px = try XCTUnwrap(rightEye ? cal.right.project(cal.leftToRight(p)) : cal.left.project(p))
            px += noisePx * SIMD2(sin(Double(i) * 2.3 + (rightEye ? 1 : 0)), cos(Double(i) * 1.7 + (rightEye ? 2 : 0)))
            return SIMD2(Float(px.x / 480), Float(px.y / 640))
        }
        return TrackedHand(landmarks: pts, confidences: [Float](repeating: 0.8, count: 21), chirality: chirality)
    }


    func testTwoHandsMatchedAcrossEyesByGeometryNotLabels() throws {
        let userLeft = hand3D(wrist: SIMD3(-0.09, 0.20, 0.25))
        let userRight = hand3D(wrist: SIMD3(0.26, 0.22, 0.23))
        // Both labelled "right" (what Vision did on the live frames) and listed in opposite orders per eye.
        let s = (left: [try tracked(userLeft, rightEye: false), try tracked(userRight, rightEye: false)],
                       right: [try tracked(userRight, rightEye: true), try tracked(userLeft, rightEye: true)])
        let hands = StereoHandFusion(calibration: cal).fuse(left: s.left, right: s.right)
        XCTAssertEqual(hands.count, 2)
        let l = try XCTUnwrap(hands.first { $0.side == .left }), r = try XCTUnwrap(hands.first { $0.side == .right })
        for i in 0..<21 {
            XCTAssertLessThan(simd_distance(l.joints[i], userLeft[i]), 0.001, "left joint \(i)")
            XCTAssertLessThan(simd_distance(r.joints[i], userRight[i]), 0.001, "right joint \(i)")
        }
        XCTAssertLessThan(l.meanRayGap, 0.001)
    }

    /// Regression (Andrew's live frames, Sun 01:28): real detections are a few pixels off, so the TRUE pairs' rays
    /// miss by ~5–10 mm, while the CROSS pairing (right hand in the left eye × left hand in the right eye) "meets"
    /// ~6 cm in front of the glasses with a smaller gap. Picking the smallest gap first fused that phantom and
    /// dropped both real hands.
    func testNoisyDetectionsStillPairTheRealHands() throws {
        let userLeft = hand3D(wrist: SIMD3(-0.09, 0.20, 0.25))
        let userRight = hand3D(wrist: SIMD3(0.26, 0.22, 0.23))
        let hands = StereoHandFusion(calibration: cal).fuse(
            left: [try tracked(userLeft, rightEye: false, noisePx: 3), try tracked(userRight, rightEye: false, noisePx: 3)],
            right: [try tracked(userLeft, rightEye: true, noisePx: 3), try tracked(userRight, rightEye: true, noisePx: 3)])
        XCTAssertEqual(hands.count, 2)
        for h in hands { XCTAssertGreaterThan(h.wrist.z, 0.15, "phantom hand at \(h.wrist)") }
        let l = try XCTUnwrap(hands.first { $0.side == .left })
        XCTAssertLessThan(simd_distance(l.wrist, userLeft[0]), 0.02)
    }

    func testHandSeenByOneEyeOnlyIsNotFused() throws {
        let h = hand3D(wrist: SIMD3(0.0, 0.2, 0.3))
        XCTAssertTrue(StereoHandFusion(calibration: cal).fuse(left: [try tracked(h, rightEye: false)], right: []).isEmpty)
    }

    func testDifferentHandsInEachEyeAreRejected() throws {
        // Left eye sees only the user's left hand, right eye only the user's right hand: no consistent 3D hand.
        let a = hand3D(wrist: SIMD3(-0.09, 0.20, 0.25)), b = hand3D(wrist: SIMD3(0.26, 0.22, 0.23))
        let hands = StereoHandFusion(calibration: cal).fuse(left: [try tracked(a, rightEye: false)],
                                                            right: [try tracked(b, rightEye: true)])
        XCTAssertTrue(hands.isEmpty, "got \(hands.map { ($0.joints[0], $0.meanRayGap) })")
    }

    func testPalmFrameIsOrthonormalAndPointsAlongTheFingers() throws {
        let joints = hand3D(wrist: SIMD3(0.05, 0.2, 0.3))
        let s = (left: [try tracked(joints, rightEye: false)], right: [try tracked(joints, rightEye: true)])
        let h = try XCTUnwrap(StereoHandFusion(calibration: cal).fuse(left: s.left, right: s.right).first)
        let m = simd_double3x3(h.orientation)
        for c in [m.columns.0, m.columns.1, m.columns.2] { XCTAssertEqual(simd_length(c), 1, accuracy: 1e-9) }
        XCTAssertEqual(simd_dot(m.columns.0, m.columns.1), 0, accuracy: 1e-9)
        // Column 1 = wrist → middle-finger knuckle: fingers point up, i.e. -y in the camera frame.
        XCTAssertLessThan(m.columns.1.y, -0.9)
        XCTAssertEqual(h.wrist, h.joints[0])
    }
}
