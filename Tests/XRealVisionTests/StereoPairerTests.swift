import XCTest
@testable import XRealVision

final class StereoPairerTests: XCTestCase {
    private func dummyImage(_ b: UInt8) -> CGImage {
        XRealFrameDecoder.makeCGImage(upright: [UInt8](repeating: b,
            count: FrameLayout.uprightWidth * FrameLayout.uprightHeight))!
    }

    func testEmitsWhenBothEyesArrive() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 5, cameraID: CameraID.left, timestampMicros: 10))
        let frame = p.accept(image: dummyImage(2), sequence: 5, cameraID: CameraID.right, timestampMicros: 10)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.sequence, 5)
        XCTAssertEqual(frame?.left.cameraID, CameraID.left)
        XCTAssertEqual(frame?.right.cameraID, CameraID.right)
        XCTAssertEqual(frame?.left.sequence, 5)
        XCTAssertEqual(p.pendingCount, 0)
    }

    func testOutOfOrderArrival() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(2), sequence: 7, cameraID: CameraID.right, timestampMicros: 1))
        XCTAssertNotNil(p.accept(image: dummyImage(1), sequence: 7, cameraID: CameraID.left, timestampMicros: 1))
    }

    func testSequenceMismatchHoldsUntilMatch() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 8, cameraID: CameraID.left, timestampMicros: 1))
        XCTAssertNil(p.accept(image: dummyImage(2), sequence: 9, cameraID: CameraID.right, timestampMicros: 1))
        let frame = p.accept(image: dummyImage(3), sequence: 8, cameraID: CameraID.right, timestampMicros: 1)
        XCTAssertEqual(frame?.sequence, 8)
        XCTAssertEqual(p.pendingCount, 1)   // seq 9's right eye still waiting
    }

    func testPendingClearedWhenOver8() {
        var p = StereoPairer()
        for i in 0..<9 {
            _ = p.accept(image: dummyImage(UInt8(i)), sequence: UInt16(i), cameraID: CameraID.left, timestampMicros: 0)
        }
        XCTAssertEqual(p.pendingCount, 0)   // spec: the whole map is cleared on overflow
    }

    func testUnknownCameraIDIgnored() {
        var p = StereoPairer()
        XCTAssertNil(p.accept(image: dummyImage(1), sequence: 3, cameraID: 0x00, timestampMicros: 0))
        XCTAssertEqual(p.pendingCount, 0)
    }
}
