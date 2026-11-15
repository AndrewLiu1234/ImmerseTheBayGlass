import XCTest
import CoreGraphics
import simd
@testable import XRealVision

final class VisionHandDetectorTests: XCTestCase {
    // Gray→RGB: single-value gray must replicate into all three channels, geometry preserved.
    private func pixelAt(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let d = img.dataProvider!.data! as Data
        let row = img.bytesPerRow
        let o = y * row + x * 3
        return (d[o], d[o + 1], d[o + 2])
    }

    func testGrayToRGBReplicatesChannels() {
        var gray = [UInt8](repeating: 0x40, count: 480 * 640)
        gray[100 * 480 + 200] = 0xAB   // row 100, col 200
        guard let rgb = GrayToRGB.convert(upright: gray, width: 480, height: 640) else {
            return XCTFail("convert returned nil")
        }
        XCTAssertEqual(rgb.width, 480)
        XCTAssertEqual(rgb.height, 640)
        XCTAssertEqual(rgb.bitsPerPixel, 24)
        XCTAssertEqual(pixelAt(rgb, 200, 100).0, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 200, 100).1, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 200, 100).2, 0xAB)
        XCTAssertEqual(pixelAt(rgb, 0, 0).0, 0x40)
    }

    // Mapper: y-flip. Vision origin is bottom-left; contract is top-left.
    func testMapperFlipsY() {
        let raw = RawHandObservation(points: [SIMD2<Float>](repeating: .zero, count: 21),
                                     chirality: .left)
        var flipped = raw
        flipped.points[0] = SIMD2<Float>(0.5, 0.25)
        let hand = HandObservationMapper.map(flipped)
        XCTAssertEqual(hand.landmarks[0].x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(hand.landmarks[0].y, 0.75, accuracy: 1e-6)   // 1 − 0.25
        XCTAssertEqual(hand.chirality, .left)
    }

    // Mapper: a full 21-joint fixture must come out in canonical order with confidences preserved.
    func testMapperFullOrderFixture() {
        var points = [SIMD2<Float>?](repeating: nil, count: 21)
        for i in 0..<21 {
            points[i] = SIMD2<Float>(Float(i) / 21.0, Float(20 - i) / 21.0)
        }
        let raw = RawHandObservation(points: points, confidences: (0..<21).map { Float($0) / 21.0 },
                                     chirality: .right)
        let hand = HandObservationMapper.map(raw)
        for i in 0..<21 {
            XCTAssertEqual(hand.landmarks[i].x, Float(i) / 21.0, accuracy: 1e-6, "joint \(i)")
            // y' = 1 − (20−i)/21 = (i+1)/21
            XCTAssertEqual(hand.landmarks[i].y, Float(i + 1) / 21.0, accuracy: 1e-6, "joint \(i) y-flipped")
            XCTAssertEqual(hand.confidences[i], Float(i) / 21.0, accuracy: 1e-6, "joint \(i) conf")
        }
    }

    // Mapper: missing joints degrade to origin + zero confidence, never crash or reorder.
    func testMapperMissingJointsBecomeZeroConfidenceOrigin() {
        var points = [SIMD2<Float>?](repeating: nil, count: 21)
        points[8] = SIMD2<Float>(0.4, 0.6)
        let hand = HandObservationMapper.map(RawHandObservation(points: points, chirality: .unknown))
        XCTAssertEqual(hand.landmarks[8].x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(hand.confidences[8], 1.0, accuracy: 1e-6)
        XCTAssertEqual(hand.landmarks[0], .zero)
        XCTAssertEqual(hand.confidences[0], 0.0)
    }

    // The Vision-name table, in canonical order — the mapping's single source of truth.
    func testVisionJointNamesMatchCanonicalOrder() {
        XCTAssertEqual(VisionHandDetector.jointNames, [
            .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip,
        ])
    }

    // The convenience wrapper must agree with the core — production uses the wrapper (frames are CGImages).
    func testGrayToRGBFromCGImageMatchesCore() {
        var gray = [UInt8](repeating: 0x20, count: 480 * 640)
        gray[640 * 480 / 2 + 240] = 0xEE
        let grayImage = XRealFrameDecoder.makeCGImage(upright: gray)!
        let rgb = GrayToRGB.convert(image: grayImage)!
        XCTAssertEqual(rgb.width, 480)
        XCTAssertEqual(rgb.bitsPerPixel, 24)
        XCTAssertEqual(pixelAt(rgb, 240, 320).0, 0xEE)
        XCTAssertEqual(pixelAt(rgb, 240, 320).1, 0xEE)
        XCTAssertEqual(pixelAt(rgb, 240, 320).2, 0xEE)
    }

    // Real Vision on a synthetic frame: no hand → empty result, and it must not throw or hang.
    func testDetectorReturnsEmptyOnBlankFrame() throws {
        let gray = [UInt8](repeating: 0x20, count: 480 * 640)
        let rgb = GrayToRGB.convert(upright: gray, width: 480, height: 640)!
        let result = try VisionHandDetector().detectHands(in: rgb)
        XCTAssertTrue(result.isEmpty)
    }
}
