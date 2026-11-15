import CoreGraphics
import Foundation
import ImageIO
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 8: offline check of Person 1's recorded datasets.
///
///     XREAL_PROBE_PNGS=live-probe-frames swift test --filter LiveFrameFretboardTests/testLiveDatasets
///
/// XREAL_PROBE_PNGS is one dataset dir (left_N.png / right_N.png) or a parent of dataset dirs (setup-still, play,
/// distance-*, occluded, clutter — see scripts/push-live-frames.sh). Lines start with `[live-fretboard]`.
/// Optional: XREAL_WRITE_GUITAR_MODEL=1 writes the setup result to tools/guitar/f600-markers.json.
final class LiveFrameFretboardTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The marker detector for real frames: Person 1's `MarkerDetector` (their Task 4).
    static func liveDetector() -> any MarkerDetecting { MarkerDetector() }

    // MARK: - Entry points

    func testLiveDatasets() throws {
        guard let root = ProcessInfo.processInfo.environment["XREAL_PROBE_PNGS"] else {
            throw XCTSkip("set XREAL_PROBE_PNGS to a dataset dir (or a dir of datasets) to run the fretboard check")
        }
        let detector = Self.liveDetector()
        if detector is NullMarkerDetector {
            throw XCTSkip("Person 1's marker detector isn't in yet (LiveFrameFretboardTests.liveDetector is the no-op one)")
        }
        let dirs = Self.datasetDirs(URL(fileURLWithPath: root))
        XCTAssertFalse(dirs.isEmpty, "no left_N/right_N pairs under \(root)")
        // Setup first, so the other datasets are tracked with the real model.
        var model: GuitarModel?
        for dir in dirs.sorted(by: { a, _ in a.lastPathComponent.contains("setup") }) {
            let r = try FretboardHarness.run(dir: dir, markers: .detector(detector), measurements: Self.measurements(),
                                             model: model, withHands: true)
            r.print()
            r.assertHealthy(file: #filePath, line: #line)
            if let m = r.setupModel {
                model = m
                if ProcessInfo.processInfo.environment["XREAL_WRITE_GUITAR_MODEL"] == "1" {
                    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try enc.encode(m).write(to: Self.repo.appendingPathComponent("tools/guitar/f600-markers.json"))
                }
            }
        }
    }

    /// The harness itself, on the synthetic fixtures through their ground-truth corners (no glasses, no detector).
    func testHarnessSelfTestOnSyntheticFixtures() throws {
        let r = try FretboardHarness.run(dir: MarkerFixtureTests.dir, markers: .fixtureTruth, name: "setup-still",
                                         measurements: GuitarTestSupport.exactMeasurements, model: nil, withHands: false,
                                         calibration: .xrealAir2Ultra)
        r.print()
        XCTAssertEqual(r.pairs, 20)
        XCTAssertEqual(r.sideErrorMedian ?? 1, 0, accuracy: 0.0005, "truth corners → 60 mm squares")
        for (_, s) in r.distanceSpread { XCTAssertLessThan(s.std, 0.0005) }
        let model = try XCTUnwrap(r.setupModel)
        XCTAssertEqual(model.scaleCheckError, 0, accuracy: 0.001)
        XCTAssertEqual(r.poseFrames, 16, "every non-clutter pair gives a guitar pose")
        r.assertHealthy(file: #filePath, line: #line)
    }

    // MARK: - Helpers

    static func measurements() -> GuitarMeasurements {
        let url = repo.appendingPathComponent("tools/guitar/f600-measurements.json")
        return (try? JSONDecoder().decode(GuitarMeasurements.self, from: Data(contentsOf: url))) ?? .f600Estimate
    }

    static func datasetDirs(_ root: URL) -> [URL] {
        func hasPairs(_ d: URL) -> Bool { FileManager.default.fileExists(atPath: d.appendingPathComponent("left_0.png").path) }
        if hasPairs(root) { return [root] }
        let subs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.filter(hasPairs).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Runs the whole fretboard pipeline over one dataset and collects the plan's Task 8 numbers.
enum FretboardHarness {
    enum MarkerSource {
        case detector(any MarkerDetecting)
        case fixtureTruth          // fixtures/markers-synthetic/truth.json corners (harness self-test)
    }

    struct Report {
        var name: String
        var pairs = 0
        var seen: [Int: (left: Int, right: Int, stereo: Int)] = [:]
        var sideErrors: [Double] = []
        var distanceSpread: [String: (mean: Double, std: Double, n: Int)] = [:]
        var totalDetections = 0
        var poseFrames = 0
        var markersUsed: [String: Int] = [:]
        var setupModel: GuitarModel?
        var setupError: String?
        var detectMs: [Double] = []
        var geometryMs: [Double] = []
        var tipHeights: [Double] = []

        var sideErrorMedian: Double? { sideErrors.isEmpty ? nil : sideErrors.sorted()[sideErrors.count / 2] }
        var isClutter: Bool { name.contains("clutter") }
        var isSetup: Bool { name.contains("setup") }

        func print() {
            func pct(_ n: Int) -> String { pairs == 0 ? "–" : String(format: "%.0f%%", 100 * Double(n) / Double(pairs)) }
            func med(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
            func p90(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, v.count * 9 / 10)] }
            Swift.print("[live-fretboard] dataset \(name): \(pairs) pairs, \(totalDetections) marker detections")
            for id in [7, 8, 9] {
                let s = seen[id] ?? (0, 0, 0)
                Swift.print("[live-fretboard]   ID \(id): left \(pct(s.left)), right \(pct(s.right)), both eyes \(pct(s.stereo))")
            }
            if !sideErrors.isEmpty {
                Swift.print(String(format: "[live-fretboard]   stereo side − 60 mm: median %.2f mm, p90 %.2f mm (target ≤ 2)",
                                   med(sideErrors) * 1000, p90(sideErrors) * 1000))
            }
            for (k, v) in distanceSpread.sorted(by: { $0.key < $1.key }) {
                Swift.print(String(format: "[live-fretboard]   centre distance %@: %.1f mm ± %.2f mm over %d pairs (target ± 2)",
                                   k, v.mean * 1000, v.std * 1000, v.n))
            }
            if let m = setupModel {
                Swift.print(String(format: "[live-fretboard]   setup: scale check %+.1f mm (nut → fret %d vs 634 mm scale), spread %.2f mm, %d frames",
                                   m.scaleCheckError * 1000, m.measurements.bodyMarkersFret, m.captureSpread * 1000, m.framesUsed))
            } else if let e = setupError {
                Swift.print("[live-fretboard]   setup FAILED: \(e)")
            }
            Swift.print("[live-fretboard]   guitar pose in \(pct(poseFrames)) of pairs; markers used: "
                        + markersUsed.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            Swift.print(String(format: "[live-fretboard]   time: markers %.2f ms/pair (median), geometry %.3f ms/pair",
                               med(detectMs), med(geometryMs)))
            if !tipHeights.isEmpty {
                let bins = stride(from: -0.01, to: 0.06, by: 0.005).map { lo in (lo, tipHeights.filter { $0 >= lo && $0 < lo + 0.005 }.count) }
                Swift.print("[live-fretboard]   fingertip height above the board (on-neck tips, n=\(tipHeights.count)): "
                            + bins.map { String(format: "%+.0f–%.0f mm: %d", $0.0 * 1000, ($0.0 + 0.005) * 1000, $0.1) }.joined(separator: " | "))
            }
        }

        /// The plan's pass/fail gates (only those this dataset can test).
        func assertHealthy(file: StaticString, line: UInt) {
            if isClutter { XCTAssertEqual(totalDetections, 0, "\(name): false marker detections on clutter", file: file, line: line) }
            if isSetup {
                XCTAssertNotNil(setupModel, "\(name): setup failed: \(setupError ?? "?")", file: file, line: line)
                if let m = sideErrorMedian { XCTAssertLessThan(m, 0.002, "\(name): stereo side length off", file: file, line: line) }
                for (k, v) in distanceSpread { XCTAssertLessThan(v.std, 0.002, "\(name): \(k) distance unstable", file: file, line: line) }
                if let s = setupModel { XCTAssertLessThan(abs(s.scaleCheckError), 0.005, "\(name): scale check", file: file, line: line) }
            }
        }
    }

    /// `calibration`: `.active` (these glasses) for real frames; the fixtures were rendered with `.xrealAir2Ultra`.
    static func run(dir: URL, markers source: MarkerSource, name: String? = nil, measurements: GuitarMeasurements,
                    model: GuitarModel?, withHands: Bool, calibration: StereoCalibration = .active) throws -> Report {
        var report = Report(name: name ?? dir.lastPathComponent)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        let indices = files.compactMap { n -> Int? in
            guard n.hasPrefix("left_"), n.hasSuffix(".png") else { return nil }
            return Int(n.dropFirst(5).dropLast(4))
        }.filter { files.contains("right_\($0).png") }.sorted()
        report.pairs = indices.count

        let truth: [Int: FixturePair] = {
            guard case .fixtureTruth = source, let t = try? MarkerFixtureTests.loadTruth() else { return [:] }
            return Dictionary(uniqueKeysWithValues: t.map { ($0.index, $0) })
        }()
        func load(_ n: String) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(n) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        func observations(_ i: Int, right: Bool) throws -> [MarkerObservation] {
            switch source {
            case .detector(let d):
                guard let img = load("\(right ? "right" : "left")_\(i).png") else { return [] }
                return try d.detectMarkers(in: img)
            case .fixtureTruth:
                guard let p = truth[i] else { return [] }
                return (right ? p.right : p.left).filter(\.visible).map { t in
                    MarkerObservation(id: t.id, corners: t.cornersPx.map { SIMD2(Float(($0.x + 0.5) / 480), Float(($0.y + 0.5) / 640)) },
                                      hammingDistance: 0)
                }
            }
        }

        let estimator = MarkerPoseEstimator(calibration: calibration)
        var perPair: [[MarkerPose3D]] = []
        var centres: [String: [Double]] = [:]
        for i in indices {
            let t0 = CFAbsoluteTimeGetCurrent()
            let l = try observations(i, right: false), r = try observations(i, right: true)
            report.detectMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            report.totalDetections += l.count + r.count
            for id in [7, 8, 9] {
                let inL = l.contains { $0.id == id }, inR = r.contains { $0.id == id }
                var s = report.seen[id] ?? (0, 0, 0)
                s.left += inL ? 1 : 0; s.right += inR ? 1 : 0; s.stereo += (inL && inR) ? 1 : 0
                report.seen[id] = s
            }
            let poses = estimator.estimate(left: l, right: r)
            perPair.append(poses)
            for p in poses { if let side = p.triangulatedSide { report.sideErrors.append(abs(side - 0.060)) } }
            let stereo = Dictionary(poses.filter { $0.source == .stereo }.map { ($0.id, $0.center) }, uniquingKeysWith: { a, _ in a })
            for (a, b) in [(7, 8), (7, 9), (8, 9)] {
                if let ca = stereo[a], let cb = stereo[b] { centres["\(a)–\(b)", default: []].append(simd_distance(ca, cb)) }
            }
        }
        for (k, v) in centres where v.count >= 2 {
            let mean = v.reduce(0, +) / Double(v.count)
            report.distanceSpread[k] = (mean, (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count - 1)).squareRoot(), v.count)
        }

        var useModel = model ?? .nominalF600
        if report.isSetup {
            do {
                let m = try GuitarSetup.build(captures: perPair.filter { !$0.isEmpty }, measurements: measurements, spec: .yamahaF600)
                report.setupModel = m
                useModel = m
            } catch { report.setupError = "\(error)" }
        }

        // Guitar pose per pair (unsmoothed: pairs may be far apart in time) + fingertip heights for tuning.
        let board = Fretboard(spec: .yamahaF600)
        let hands = withHands ? VisionHandDetector() : nil
        let fusion = StereoHandFusion(calibration: calibration)
        for (n, i) in indices.enumerated() {
            let t0 = CFAbsoluteTimeGetCurrent()
            var tracker = GuitarTracker(model: useModel, smoothing: false)
            let pose = tracker.update(perPair[n], timestamp: 0)
            report.geometryMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard let pose else { continue }
            report.poseFrames += 1
            report.markersUsed[pose.markersUsed.map(String.init).joined(separator: "+"), default: 0] += 1
            if let hands, let li = load("left_\(i).png").flatMap(GrayToRGB.convert(image:)),
               let ri = load("right_\(i).png").flatMap(GrayToRGB.convert(image:)) {
                let h3 = fusion.fuse(left: try hands.detectHands(in: li), right: try hands.detectHands(in: ri))
                for h in h3 {
                    report.tipHeights += FingerOnFretboard.place(hand: h, pose: pose, board: board).filter(\.onNeck).map(\.height)
                }
            }
        }
        return report
    }
}

final class GuitarMeasurementsFileTests: XCTestCase {
    func testShippedMeasurementsFileDecodes() throws {
        let url = LiveFrameFretboardTests.repo.appendingPathComponent("tools/guitar/f600-measurements.json")
        let m = try JSONDecoder().decode(GuitarMeasurements.self, from: Data(contentsOf: url))
        XCTAssertEqual(m.bodyMarkersFret, 14)
        XCTAssertGreaterThan(m.headstockEdgeToNut, 0)
    }
}
