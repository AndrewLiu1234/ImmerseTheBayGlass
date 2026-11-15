import CoreGraphics
import Foundation
import ImageIO
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Live-data check of the 3-D hand path on real probe dumps (left_N.png / right_N.png = one stereo pair):
///     XREAL_PROBE_PNGS=/path/to/live-probe-frames swift test --filter LiveFrameStereoFusionTests
/// Skips without the env var. Checks physical sanity, not exact values: the eyes' rays meet, hands sit at arm's
/// length in front of the glasses, and bone lengths stay constant frame to frame (a bad calibration stretches them).
final class LiveFrameStereoFusionTests: XCTestCase {
    func testFusedHandsArePhysicallyPlausible() throws {
        guard let dir = ProcessInfo.processInfo.environment["XREAL_PROBE_PNGS"] else {
            throw XCTSkip("set XREAL_PROBE_PNGS to a probe PNG directory to run the live 3-D check")
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir))
        let indices = names.compactMap { n -> Int? in
            guard n.hasPrefix("left_"), n.hasSuffix(".png") else { return nil }
            return Int(n.dropFirst(5).dropLast(4))
        }.filter { names.contains("right_\($0).png") }.sorted()
        XCTAssertFalse(indices.isEmpty, "no left_N/right_N pairs in \(dir)")

        let detector = VisionHandDetector()
        let fusion = StereoHandFusion(calibration: .xrealAir2Ultra)
        func load(_ name: String) throws -> CGImage {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(GrayToRGB.convert(image: try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))))
        }
        func bone(_ h: Hand3D, _ a: HandJoint, _ b: HandJoint) -> Double { simd_distance(h.joints[a.rawValue], h.joints[b.rawValue]) }

        var gaps: [Double] = [], depths: [Double] = [], spans: [Double] = [], fuseMs: [Double] = []
        var palm: [Hand3D.Side: [Double]] = [.left: [], .right: []]
        var bothEyesTwo = 0, fusedTwo = 0
        for i in indices {
            let l = try detector.detectHands(in: try load("left_\(i).png"))
            let r = try detector.detectHands(in: try load("right_\(i).png"))
            let t0 = CFAbsoluteTimeGetCurrent()
            let hands = fusion.fuse(left: l, right: r)
            fuseMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if l.count == 2 && r.count == 2 { bothEyesTwo += 1; if hands.count == 2 { fusedTwo += 1 } }
            for h in hands {
                gaps.append(h.meanRayGap); depths.append(h.wrist.z)
                palm[h.side]?.append(bone(h, .wrist, .middleMCP))
            }
            if hands.count == 2 { spans.append(simd_distance(hands[0].wrist, hands[1].wrist)) }
            let desc = hands.map { h in
                String(format: "%@ wrist (%+.3f, %+.3f, %+.3f) m gap %.1f mm", h.side == .left ? "L" : "R",
                       h.wrist.x, h.wrist.y, h.wrist.z, h.meanRayGap * 1000)
            }.joined(separator: " | ")
            print("[live-3d] pair \(i): eyes \(l.count)/\(r.count) → \(hands.count) 3-D: \(desc)")
        }

        func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
        func spread(_ v: [Double]) -> Double {
            guard v.count > 1 else { return .nan }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
        }
        print(String(format: "[live-3d] summary: %d pairs, both eyes 2 hands in %d, fused both in %d | ray gap median %.1f mm, max %.1f mm | wrist depth median %.3f m | hand span median %.3f m | wrist→middle knuckle L %.1f±%.1f mm, R %.1f±%.1f mm | fuse %.3f ms",
                     indices.count, bothEyesTwo, fusedTwo, median(gaps) * 1000, (gaps.max() ?? .nan) * 1000,
                     median(depths), median(spans), median(palm[.left]!) * 1000, spread(palm[.left]!) * 1000,
                     median(palm[.right]!) * 1000, spread(palm[.right]!) * 1000, median(fuseMs)))

        XCTAssertGreaterThan(fusedTwo, bothEyesTwo * 9 / 10, "most pairs with both hands in both eyes should fuse")
        XCTAssertLessThan(median(gaps), 0.015, "eyes' rays should meet within ~1.5 cm")
        XCTAssertTrue((0.1...1.0).contains(median(depths)), "hands should be at arm's length")
        for side in [Hand3D.Side.left, .right] where (palm[side]?.count ?? 0) > 5 {
            XCTAssertTrue((0.05...0.13).contains(median(palm[side]!)), "palm length should be human-sized")
            XCTAssertLessThan(spread(palm[side]!), 0.015, "palm length should stay constant frame to frame")
        }
    }
}
