import XCTest
import CoreGraphics
import simd
@testable import XRealMirrorApp
import XRealVision

final class SkeletonGeometryTests: XCTestCase {
    // The trap: the 480x640 image is letterboxed inside the pane by .resizeAspect — landmarks are
    // normalized to the IMAGE, so every drawing path must go through this mapping.
    func testAspectFitPortraitInWidePane() {
        let r = AspectFitRect.fit(imageWidth: 480, imageHeight: 640,
                                  in: CGRect(x: 0, y: 0, width: 1000, height: 400))
        // height-bound: scale = 400/640 = 0.625 → 300x400, centered horizontally
        XCTAssertEqual(r.width, 300, accuracy: 0.001)
        XCTAssertEqual(r.height, 400, accuracy: 0.001)
        XCTAssertEqual(r.midX, 500, accuracy: 0.001)
        XCTAssertEqual(r.midY, 200, accuracy: 0.001)
    }

    func testAspectFitLandscapeInWidePane() {
        let r = AspectFitRect.fit(imageWidth: 640, imageHeight: 480,
                                  in: CGRect(x: 0, y: 0, width: 1000, height: 400))
        // width-bound: scale = 400/480 = 0.8333 → 533.33x400, centered
        XCTAssertEqual(r.width, 1000 * 0.8 / 1.5, accuracy: 0.01)
        XCTAssertEqual(r.height, 400, accuracy: 0.001)
        XCTAssertEqual(r.midX, 500, accuracy: 0.001)
    }

    func testAspectFitExactMatchAndOffsetContainer() {
        XCTAssertEqual(AspectFitRect.fit(imageWidth: 100, imageHeight: 200,
                                         in: CGRect(x: 0, y: 0, width: 100, height: 200)),
                       CGRect(x: 0, y: 0, width: 100, height: 200))
        // 100x100 image in a 200x300 container: width-bound (scale 2) → 200x200, centered → x = 10, y = 70
        let r = AspectFitRect.fit(imageWidth: 100, imageHeight: 100,
                                  in: CGRect(x: 10, y: 20, width: 200, height: 300))
        XCTAssertEqual(r, CGRect(x: 10, y: 70, width: 200, height: 200))
    }

    func testAspectFitDegenerateContainer() {
        XCTAssertEqual(AspectFitRect.fit(imageWidth: 480, imageHeight: 640, in: .zero), .zero)
    }

    private func hand(_ pts: [SIMD2<Float>]) -> TrackedHand {
        TrackedHand(landmarks: pts, confidences: [Float](repeating: 1, count: pts.count), chirality: .right)
    }

    // Contract points are normalized top-left; geometry maps them into the image rect.
    func testBuilderMapsPointIntoRect() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        pts[0] = SIMD2<Float>(0.5, 0.5)          // wrist at image center
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(geo.dots.count, 21)
        XCTAssertEqual(geo.lines.count, 21)      // HandSkeleton.connections, all 21
        XCTAssertEqual(geo.dots[0], CGPoint(x: 60, y: 120))
    }

    func testBuilderCornerMapping() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        pts[0] = SIMD2<Float>(0, 0)              // top-left of the image
        pts[1] = SIMD2<Float>(1, 1)              // bottom-right
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(geo.dots[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(geo.dots[1], CGPoint(x: 110, y: 220))
    }

    func testBuilderLineEndpointsAreMappedDots() {
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        for i in 0..<21 { pts[i] = SIMD2<Float>(Float(i % 7) / 7, Float(i % 5) / 5) }
        let geo = SkeletonPathBuilder.geometry(hand: hand(pts), in: CGRect(x: 0, y: 0, width: 700, height: 500))
        for (line, conn) in zip(geo.lines, HandSkeleton.connections) {
            XCTAssertEqual(line.0, geo.dots[conn.from])
            XCTAssertEqual(line.1, geo.dots[conn.to])
        }
    }
}
