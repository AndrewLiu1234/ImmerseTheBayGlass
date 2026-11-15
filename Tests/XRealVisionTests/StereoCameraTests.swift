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
}
