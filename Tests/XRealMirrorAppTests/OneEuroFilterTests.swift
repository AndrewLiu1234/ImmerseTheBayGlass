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
