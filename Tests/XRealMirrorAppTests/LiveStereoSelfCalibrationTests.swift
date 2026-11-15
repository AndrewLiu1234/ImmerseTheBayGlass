import CoreGraphics
import Foundation
import ImageIO
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fits these glasses' stereo extrinsics from a still marker capture and validates on held-out pairs:
///     XREAL_PROBE_PNGS=live-probe-frames/setup-still XREAL_HAND_PNGS=live-probe-frames \
///         swift test -c release -Xswiftc -enable-testing --filter LiveStereoSelfCalibrationTests
/// Markers fix the scale; matched hand joints (optional, XREAL_HAND_PNGS) fix the epipolar geometry the still
/// marker scene can't. Fits on EVEN pairs of both, validates on ODD pairs of both.
final class LiveStereoSelfCalibrationTests: XCTestCase {
    func testFitOnHalfValidateOnTheOtherHalf() throws {
        guard let path = ProcessInfo.processInfo.environment["XREAL_PROBE_PNGS"] else {
            throw XCTSkip("set XREAL_PROBE_PNGS to a still marker capture (e.g. live-probe-frames/setup-still)")
        }
        let dir = URL(fileURLWithPath: path), detector = MarkerDetector()
        func load(_ n: String) -> CGImage? {
            guard let s = CGImageSourceCreateWithURL(dir.appendingPathComponent(n) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(s, 0, nil)
        }
        var obsByPair: [Int: [StereoSelfCalibration.Observation]] = [:]
        for i in 0..<200 {
            guard let l = load("left_\(i).png"), let r = load("right_\(i).png") else { break }
            let lm = try detector.detectMarkers(in: l), rm = try detector.detectMarkers(in: r)
            obsByPair[i] = lm.compactMap { lo in
                rm.first { $0.id == lo.id }.map { ro in
                    .init(id: lo.id, left: MarkerPoseEstimator.pixels(lo), right: MarkerPoseEstimator.pixels(ro))
                }
            }
        }
        let even = obsByPair.filter { $0.key % 2 == 0 }.flatMap(\.value), odd = obsByPair.filter { $0.key % 2 == 1 }.flatMap(\.value)
        let ref = StereoCalibration.xrealAir2Ultra

        // Hand joints matched across eyes (pairing by the reference fusion, which fused 70/70 on the live frames).
        var handPairs: [Int: [StereoSelfCalibration.PointPair]] = [:]
        var handFrames: [Int: ([TrackedHand], [TrackedHand])] = [:]
        if let hp = ProcessInfo.processInfo.environment["XREAL_HAND_PNGS"] {
            let hdir = URL(fileURLWithPath: hp), hd = VisionHandDetector(), fusion = StereoHandFusion(calibration: ref)
            func px(_ n: SIMD2<Float>) -> SIMD2<Double> { SIMD2(Double(n.x) * 480 - 0.5, Double(n.y) * 640 - 0.5) }
            for i in 0..<200 {
                func img(_ n: String) -> CGImage? {
                    CGImageSourceCreateWithURL(hdir.appendingPathComponent(n) as CFURL, nil)
                        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.flatMap(GrayToRGB.convert(image:))
                }
                guard let li = img("left_\(i).png"), let ri = img("right_\(i).png") else { break }
                let l = try hd.detectHands(in: li), r = try hd.detectHands(in: ri)
                handFrames[i] = (l, r)
                for h in fusion.fuse(left: l, right: r) {
                    // Which tracked hand in each eye is this 3-D hand? The one whose wrist is nearest its projection.
                    guard let wl = ref.left.project(h.wrist), let wr = ref.right.project(ref.leftToRight(h.wrist)),
                          let a = l.min(by: { simd_distance(px($0.landmarks[0]), wl) < simd_distance(px($1.landmarks[0]), wl) }),
                          let b = r.min(by: { simd_distance(px($0.landmarks[0]), wr) < simd_distance(px($1.landmarks[0]), wr) })
                    else { continue }
                    for j in 0..<21 where a.confidences[j] >= 0.5 && b.confidences[j] >= 0.5 {
                        handPairs[i, default: []].append(.init(left: px(a.landmarks[j]), right: px(b.landmarks[j])))
                    }
                }
            }
        }
        let handEven = handPairs.filter { $0.key % 2 == 0 }.flatMap(\.value)
        print("[self-cal] inputs: \(even.count + odd.count) marker views, \(handPairs.values.map(\.count).reduce(0, +)) hand-joint pairs")
        let fitMarkersOnly = try XCTUnwrap(StereoSelfCalibration.fit(even, start: ref))
        let fitHalf = try XCTUnwrap(StereoSelfCalibration.fit(even, points: handEven, start: ref))
        func handGap(_ cal: StereoCalibration) -> Double {
            let f = StereoHandFusion(calibration: cal)
            let g = handFrames.filter { $0.key % 2 == 1 }.flatMap { f.fuse(left: $0.value.0, right: $0.value.1).map(\.meanRayGap) }.sorted()
            return g.isEmpty ? .nan : g[g.count / 2]
        }

        func sideError(_ obs: [StereoSelfCalibration.Observation], _ cal: StereoCalibration) -> (median: Double, p90: Double) {
            let est = MarkerPoseEstimator(calibration: cal)
            let e = obs.compactMap { o in est.stereo(id: o.id, left: o.left, right: o.right)?.triangulatedSide }.map { abs($0 - 0.060) }.sorted()
            return e.isEmpty ? (.nan, .nan) : (e[e.count / 2], e[min(e.count - 1, e.count * 9 / 10)])
        }
        func lr(_ obs: [StereoSelfCalibration.Observation], _ cal: StereoCalibration) -> Double {
            // Left-only vs right-only marker centre disagreement (both use the known 60 mm side), median mm.
            let est = MarkerPoseEstimator(calibration: cal)
            let d = obs.compactMap { o -> Double? in
                guard let a = est.single(id: o.id, pixels: o.left, rightEye: false),
                      let b = est.single(id: o.id, pixels: o.right, rightEye: true) else { return nil }
                return simd_distance(a.center, b.center)
            }.sorted()
            return d.isEmpty ? .nan : d[d.count / 2]
        }
        for (label, cal) in [("reference (xr-gate unit)", ref), ("markers only, even", fitMarkersOnly.calibration),
                             ("markers + hands, even", fitHalf.calibration)] {
            let s = sideError(odd, cal), c = cal.rightCenterInLeft
            print(String(format: "[self-cal] held-out ODD, %@: marker joint rms %.2f px | |side−60| median %.2f p90 %.2f mm | L-vs-R centre %.1f mm | HAND ray gap %.1f mm | right cam at (%.1f, %.1f, %.1f) mm",
                         label, StereoSelfCalibration.jointRMS(odd, cal: cal), s.median * 1000, s.p90 * 1000, lr(odd, cal) * 1000,
                         handGap(cal) * 1000, c.x * 1000, c.y * 1000, c.z * 1000))
        }
        let full = try XCTUnwrap(StereoSelfCalibration.fit(even + odd, points: handPairs.values.flatMap { $0 }, start: ref))
        let c = full.calibration, r = c.rotation
        print(String(format: "[self-cal] ALL pairs (%d views used): rms %.2f → %.2f px, baseline %.2f mm (ref %.2f)",
                     full.observationsUsed, full.rmsBefore, full.rmsAfter, simd_length(c.rightCenterInLeft) * 1000,
                     simd_length(ref.rightCenterInLeft) * 1000))
        print("[self-cal] rotation rows: [\(r.transpose.columns.0.x), \(r.transpose.columns.0.y), \(r.transpose.columns.0.z)], [\(r.transpose.columns.1.x), \(r.transpose.columns.1.y), \(r.transpose.columns.1.z)], [\(r.transpose.columns.2.x), \(r.transpose.columns.2.y), \(r.transpose.columns.2.z)]")
        print("[self-cal] translation: [\(c.translation.x), \(c.translation.y), \(c.translation.z)]")
        XCTAssertLessThan(StereoSelfCalibration.jointRMS(odd, cal: fitHalf.calibration), StereoSelfCalibration.jointRMS(odd, cal: ref),
                          "the fit must improve HELD-OUT marker pairs, not just the ones it was fitted on")
        if !handFrames.isEmpty {
            XCTAssertLessThanOrEqual(handGap(fitHalf.calibration), handGap(ref) * 1.05, "and must not make held-out HAND triangulation worse")
        }
    }
}
