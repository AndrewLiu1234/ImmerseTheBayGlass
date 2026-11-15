import XCTest
import simd
@testable import XRealMirrorApp

final class Hands3DSceneTests: XCTestCase {
    func testCameraFrameMapsToSceneFrame() {
        // Camera: x right, y down, z forward. Scene (SceneKit): x right, y up, the glasses look down -z.
        XCTAssertEqual(Hands3DScene.scenePoint(SIMD3(0.1, 0.2, 0.3)), SIMD3<Float>(0.1, -0.2, -0.3))
    }

    func testBoneSpansItsTwoJoints() {
        let a = SIMD3<Float>(0.1, 0.0, -0.3), b = SIMD3<Float>(0.1, 0.05, -0.25)
        let bone = Hands3DScene.bone(from: a, to: b)
        XCTAssertEqual(bone.length, simd_distance(a, b), accuracy: 1e-6)
        XCTAssertLessThan(simd_distance(bone.position, (a + b) / 2), 1e-6)
        // SCNCylinder runs along its local +y: rotated, it must point from a to b.
        let axis = bone.orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertLessThan(simd_distance(axis, simd_normalize(b - a)), 1e-5)
    }

    func testBoneAlongNegativeYDoesNotDegenerate() {
        let bone = Hands3DScene.bone(from: SIMD3(0, 0, 0), to: SIMD3(0, -0.04, 0))
        let axis = bone.orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertLessThan(simd_distance(axis, SIMD3(0, -1, 0)), 1e-5)
        XCTAssertTrue(bone.orientation.vector.x.isFinite)
    }
}
