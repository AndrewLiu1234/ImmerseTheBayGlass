import XCTest
@testable import XRealVision

final class HandTrackingBenchmarkTests: XCTestCase {
    // Smoke bound only: catches a gross regression (e.g. a broken request config), never a micro-budget.
    // The real 15ms/pair budget is verified live on the glasses; CI stays honest with 10x headroom.
    func testDetectorSmokeBudget() throws {
        let rgb = GrayToRGB.convert(upright: [UInt8](repeating: 0x30, count: 480 * 640),
                                    width: 480, height: 640)!
        let detector = VisionHandDetector()
        _ = try detector.detectHands(in: rgb)          // warmup (model load, queue setup)
        var times: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try detector.detectHands(in: rgb)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "[hand-tracking benchmark] median %.2f ms/call, min %.2f, max %.2f (480x640, %d calls)",
                     median, times.min()!, times.max()!, times.count))
        XCTAssertLessThan(median, 100.0)
    }
}
