import XCTest
import simd
@testable import XRealMirrorApp

final class StereoCalibrationTests: XCTestCase {
    let cal = StereoCalibration.xrealAir2Ultra

    func testBaselineAndToeOutMatchTheCalibration() {
        // xr-gate camchain (Air 2 Ultra, unit ZBBM5DZFMP): right camera ≈ 13.6 cm to the right, toed out ≈ 9.9°.
        XCTAssertEqual(simd_length(cal.rightCenterInLeft), 0.1364, accuracy: 0.0005)
        XCTAssertGreaterThan(cal.rightCenterInLeft.x, 0.13)   // right camera sits at +x of the left one
    }

    func testProjectUnprojectRoundTrip() {
        for lens in [cal.left, cal.right] {
            for px in [SIMD2<Double>(240, 320), SIMD2(30, 40), SIMD2(450, 600), SIMD2(100, 500)] {
                let ray = lens.unproject(pixel: px)
                XCTAssertEqual(simd_length(ray), 1, accuracy: 1e-9)
                let back = lens.project(ray * 0.7)!
                XCTAssertEqual(back.x, px.x, accuracy: 1e-6)
                XCTAssertEqual(back.y, px.y, accuracy: 1e-6)
            }
        }
    }

    func testPrincipalPointUnprojectsStraightAhead() {
        let ray = cal.left.unproject(pixel: SIMD2(cal.left.cx, cal.left.cy))
        XCTAssertEqual(ray.z, 1, accuracy: 1e-12)
    }

    func testTriangulateRecoversAKnownPoint() throws {
        // A fingertip 25 cm ahead, a bit left and below: project into both cameras, triangulate back.
        for p in [SIMD3<Double>(-0.05, 0.10, 0.25), SIMD3(0.20, 0.15, 0.40), SIMD3(0.07, -0.02, 0.60)] {
            let pl = try XCTUnwrap(cal.left.project(p))
            let pr = try XCTUnwrap(cal.right.project(cal.leftToRight(p)))
            let r = try XCTUnwrap(cal.triangulate(leftPixel: pl, rightPixel: pr))
            XCTAssertLessThan(simd_distance(r.point, p), 1e-6)
            XCTAssertLessThan(r.rayGap, 1e-6)
        }
    }

    func testTriangulateRejectsPointsBehindTheCameras() {
        // Mismatched pixels (the wrong hand in the other eye) that only "meet" behind the glasses.
        XCTAssertNil(cal.triangulate(leftPixel: SIMD2(168, 480), rightPixel: SIMD2(302, 480)))
    }
}
