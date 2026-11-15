import AVFoundation
import XCTest
@testable import XRealVision

final class StereoCameraTests: XCTestCase {
    /// stop() must not deadlock when called from the capture queue itself —
    /// rawFrameHandler runs there, and a handler that calls stop() is the
    /// natural "stop after N frames" pattern. The unstarted camera also pins
    /// stop-before-start as a no-op (it used to reach stopRunning() and raise
    /// an uncaught NSException).
    func testStopFromCaptureQueueDoesNotDeadlock() {
        let camera = StereoCamera()
        let finished = expectation(description: "stop() returns when called on the capture queue")
        camera.queue.async {
            camera.stop()
            finished.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 1.0), .completed,
                       "stop() deadlocked: queue.sync executed on its own serial queue")
    }

    /// Video sample buffers from AVCaptureVideoDataOutput are image-buffer-backed:
    /// CMSampleBufferGetDataBuffer is nil for them, and the camera path dropped every
    /// frame behind that guard. rawBytes must read the CVPixelBuffer instead.
    func testRawBytesReadsImageBufferBackedVideoFrame() {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 241,   // the device's packed 'yuvs' geometry: 640x241 x 2 bytes
                            kCVPixelFormatType_422YpCbCr8, nil, &pixelBuffer)
        let buffer = pixelBuffer!

        let count = FrameLayout.frameBytes   // 308,480 — the device's exact payload size
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        for i in 0..<count {
            base.storeBytes(of: UInt8((i &* 131 &+ 17) & 0xFF), toByteOffset: i, as: UInt8.self)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo()
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sampleBuffer)

        let bytes = StereoCamera.rawBytes(from: sampleBuffer!)
        XCTAssertEqual(bytes?.count, count, "rawBytes must return the full 308,480-byte payload")
        XCTAssertEqual(bytes?[0], UInt8(17), "byte 0 of the known pattern")
        XCTAssertEqual(bytes?[1], UInt8((131 &+ 17) & 0xFF), "byte 1 of the known pattern")
        XCTAssertEqual(bytes?[count - 1],
                       UInt8(((count - 1) &* 131 &+ 17) & 0xFF), "last byte of the known pattern")
    }
}
