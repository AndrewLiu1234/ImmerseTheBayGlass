import CoreGraphics
import Foundation
import XCTest
@testable import XRealVision

/// Live-verification harness: run Vision hand detection over PNG frames dumped by the stage-1
/// probe (Sources/XRealProbe, writes `left_i.png` / `right_i.png`, 480x640 grayscale).
/// Point it at the probe's output directory:
///
///     XREAL_PROBE_PNGS=/path/to/probe-out swift test --filter LiveFrameHandDetectionTests
///
/// The test passes as long as the files decode and detect without throwing — the verdict on
/// hand tracking is in the printed report (hands found per frame, joint confidences, latency).
final class LiveFrameHandDetectionTests: XCTestCase {
    func testDetectHandsInProbePNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["XREAL_PROBE_PNGS"] else {
            throw XCTSkip("set XREAL_PROBE_PNGS to the probe's PNG output directory to run the live check")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".png") }.sorted()
        XCTAssertFalse(names.isEmpty, "no PNGs in \(dir)")

        let detector = VisionHandDetector()
        var timings: [Double] = []
        var frames = 0
        var handFrames = 0
        var report: [String] = []
        print("[live-hand-detection] dir: \(dir), frames: \(names.count)")
        for name in names {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let gray = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                XCTFail("cannot decode \(name)"); continue
            }
            guard let rgb = GrayToRGB.convert(image: gray) else {
                XCTFail("gray→RGB failed for \(name)"); continue
            }
            let start = CFAbsoluteTimeGetCurrent()
            let hands = try detector.detectHands(in: rgb)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append(ms); frames += 1
            if !hands.isEmpty { handFrames += 1 }
            report.append("\(name) \(hands.count)")
            print("[live-hand-detection] \(name): \(hands.count) hand(s), \(String(format: "%.2f", ms)) ms")
            for hand in hands {
                let confident = zip(hand.confidences, HandJoint.allCases).filter { $0.0 >= 0.3 }
                let mean = confident.isEmpty ? 0 : confident.map(\.0).reduce(0, +) / Float(confident.count)
                let wrist = hand.landmarks[HandJoint.wrist.rawValue]
                print("  \(hand.chirality): \(confident.count)/21 joints ≥0.3, mean \(String(format: "%.2f", mean)), wrist (x: \(String(format: "%.2f", wrist.x)), y: \(String(format: "%.2f", wrist.y)))")
            }
        }
        let sorted = timings.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print("[live-hand-detection] summary: \(handFrames)/\(frames) frames with hands, median \(String(format: "%.2f", median)) ms/frame")
        // XCTest can drop captured stdout at high volume — the report file is the durable result.
        try report.joined(separator: "\n")
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("detection-report.txt"),
                   atomically: true, encoding: .utf8)
    }
}
