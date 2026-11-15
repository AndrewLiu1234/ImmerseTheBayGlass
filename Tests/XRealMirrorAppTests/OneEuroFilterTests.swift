import XCTest
@testable import XRealMirrorApp
import simd

final class OneEuroFilterTests: XCTestCase {
    // Pinned defaults from the spec's smoothing character: smooth but not floaty.
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(SIMD2<Float>(0.3, 0.7), timestamp: 0.0), SIMD2<Float>(0.3, 0.7))
    }

    func testConstantInputConverges() {
        var f = OneEuroFilter()
        let target = SIMD2<Float>(0.42, 0.58)
        var out = f.filter(target, timestamp: 0.0)
        for i in 1...90 { out = f.filter(target, timestamp: Double(i) / 30.0) }   // 3 s at 30fps
        XCTAssertLessThan(simd_distance(out, target), 0.01)
    }

    func testStepSettlesWithinHalfSecond() {
        var f = OneEuroFilter()
        var out = f.filter(.zero, timestamp: 0.0)
        for i in 1...60 { out = f.filter(.zero, timestamp: Double(i) / 30.0) }    // settle at 0
        out = f.filter(SIMD2<Float>(1, 1), timestamp: 61.0 / 30.0)
        for i in 62...76 { out = f.filter(SIMD2<Float>(1, 1), timestamp: Double(i) / 30.0) }
        XCTAssertGreaterThan(out.x, 0.9)   // a half second after the step, ~90% of the way there
        XCTAssertGreaterThan(out.y, 0.9)
    }
}

final class OneEuroFilter3Tests: XCTestCase {
    func testFirstSamplePassesThroughAndConstantConverges() {
        var f = OneEuroFilter3()
        let p = SIMD3<Double>(0.1, -0.2, 0.3)
        XCTAssertLessThan(simd_distance(f.filter(p, timestamp: 0), p), 1e-6)   // single-precision inside: < 1 µm
        var out = f.filter(SIMD3(0.2, 0.1, 0.25), timestamp: 1.0 / 30)
        for i in 2...90 { out = f.filter(SIMD3(0.2, 0.1, 0.25), timestamp: Double(i) / 30) }
        XCTAssertLessThan(simd_distance(out, SIMD3(0.2, 0.1, 0.25)), 0.001)
    }

    func testStepInDepthSettlesWithinHalfSecond() {
        var f = OneEuroFilter3()
        _ = f.filter(SIMD3(0, 0, 0.2), timestamp: 0)
        var out = SIMD3<Double>()
        for i in 1...15 { out = f.filter(SIMD3(0, 0, 0.4), timestamp: Double(i) / 30) }
        XCTAssertGreaterThan(out.z, 0.2 + 0.9 * 0.2)
    }
}
