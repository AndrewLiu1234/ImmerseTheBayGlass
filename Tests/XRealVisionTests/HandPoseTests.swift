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
