import CoreGraphics
import Foundation
import ImageIO
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Competing prototype ArUco detector (test-target only). Report lines start with `[proto-detector]`.
///
///     swift test --filter PrototypeMarkerDetectorTests            # debug timings
///     swift test -c release --filter PrototypeMarkerDetectorTests # release timings
final class PrototypeMarkerDetectorTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let setupStill = repo.appendingPathComponent("live-probe-frames/setup-still")
    static let phonePhoto = URL(fileURLWithPath: "/Users/bradwu/Downloads/IMG_3385.HEIC")

    let detector = PrototypeMarkerDetector()

    // MARK: - Helpers

    static func fixtureGray(_ name: String) throws -> GrayImage {
        let g = try MarkerFixtureTests.loadGray(name)
        return GrayImage(width: g.width, height: g.height, pixels: g.pixels)
    }

    static func cgImage(_ g: GrayImage) -> CGImage {
        let provider = CGDataProvider(data: Data(g.pixels) as CFData)!
        return CGImage(width: g.width, height: g.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: g.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func loadCG(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        if let maxPixelSize {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
            return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
        }
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// Rotates an image 90° clockwise `quarterTurns` times; returns the image and the matching point map
    /// (OpenCV pixel-centre convention).
    static func rotated(_ g: GrayImage, quarterTurns: Int) -> (GrayImage, (SIMD2<Double>) -> SIMD2<Double>) {
        var img = g
        var map: (SIMD2<Double>) -> SIMD2<Double> = { $0 }
        for _ in 0..<(quarterTurns % 4) {
            let w = img.width, h = img.height
            var out = [UInt8](repeating: 0, count: w * h)
            // new (x', y') = (h-1-y, x); new width = h.
            for y in 0..<h { for x in 0..<w { out[x * h + (h - 1 - y)] = img.pixels[y * w + x] } }
            let prev = map
            map = { p in let q = prev(p); return SIMD2(Double(h - 1) - q.y, q.x) }
            img = GrayImage(width: h, height: w, pixels: out)
        }
        return (img, map)
    }

    static func mirrored(_ g: GrayImage) -> GrayImage {
        var out = g.pixels
        for y in 0..<g.height { for x in 0..<g.width { out[y * g.width + x] = g.pixels[y * g.width + (g.width - 1 - x)] } }
        return GrayImage(width: g.width, height: g.height, pixels: out)
    }

    /// Smaller of the two mid-line extents of a quad — "how many pixels across" in its thinnest direction.
    static func minExtent(_ c: [SIMD2<Double>]) -> Double {
        let w = simd_distance((c[0] + c[3]) / 2, (c[1] + c[2]) / 2)
        let h = simd_distance((c[0] + c[1]) / 2, (c[3] + c[2]) / 2)
        return min(w, h)
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func fmt(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }

    // MARK: - Synthetic fixtures: recall, corner accuracy, clutter, wrong IDs

    func testSyntheticFixtureRecallAndCornerAccuracy() throws {
        let pairs = try MarkerFixtureTests.loadTruth()
        struct Bucket { var total = 0; var found = 0 }
        var recall: [String: Bucket] = [:]
        var axisSq: [Double] = [], euclid: [Double] = []          // ≥ 24 px subset
        var axisSqAll: [Double] = [], euclidAll: [Double] = []    // every detected marker
        var clutterDetections = 0, wrongIDs = 0, unrefined = 0
        var missedBig: [String] = []

        for p in pairs {
            for eye in ["left", "right"] {
                let g = try Self.fixtureGray("\(eye)_\(p.index).png")
                let det = detector.detect(g)
                unrefined += det.filter { !$0.refined }.count
                let found = det.map(\.marker)
                let truth = eye == "left" ? p.left : p.right
                if p.kind == "clutter" { clutterDetections += found.count; continue }
                for d in found {
                    // A detection is right only if its ID is a visible marker here and it sits on that marker.
                    guard let t = truth.first(where: { $0.id == d.id && $0.visible }),
                          zip(d.corners, t.cornersPx).map({ simd_distance($0, $1) }).max()! < 3 else {
                        wrongIDs += 1
                        print("[proto-detector] WRONG pair \(p.index) \(eye) id \(d.id) corners \(d.corners)")
                        continue
                    }
                    _ = t
                }
                for t in truth where t.visible {
                    let big = Self.minExtent(t.cornersPx) >= 24
                    let keys = [p.kind, big ? "\(p.kind)>=24" : "\(p.kind)<24", big ? "all>=24" : "all<24"]
                    let hit = found.first { d in
                        d.id == t.id && zip(d.corners, t.cornersPx).map({ simd_distance($0, $1) }).max()! < 3
                    }
                    for k in keys { recall[k, default: Bucket()].total += 1; if hit != nil { recall[k]!.found += 1 } }
                    if big && hit == nil { missedBig.append("pair \(p.index) \(eye) id \(t.id)") }
                    guard let hit else { continue }
                    for (a, b) in zip(hit.corners, t.cornersPx) {
                        let e = a - b
                        axisSqAll += [e.x * e.x, e.y * e.y]; euclidAll.append(simd_length(e))
                        if big { axisSq += [e.x * e.x, e.y * e.y]; euclid.append(simd_length(e)) }
                    }
                }
            }
        }
        for k in recall.keys.sorted() {
            let b = recall[k]!
            print("[proto-detector] fixture recall \(k): \(b.found)/\(b.total) = \(Self.fmt(Double(b.found) / Double(max(b.total, 1)) * 100, 1)) %")
        }
        let rms = sqrt(axisSq.reduce(0, +) / Double(max(axisSq.count, 1)))
        let rmsAll = sqrt(axisSqAll.reduce(0, +) / Double(max(axisSqAll.count, 1)))
        print("[proto-detector] corner error (markers >= 24 px, \(euclid.count) corners): RMS per axis \(Self.fmt(rms)) px, p90 euclid \(Self.fmt(Self.percentile(euclid, 0.9))) px, max \(Self.fmt(euclid.max() ?? .nan)) px")
        print("[proto-detector] corner error (all detected, \(euclidAll.count) corners): RMS per axis \(Self.fmt(rmsAll)) px, p90 euclid \(Self.fmt(Self.percentile(euclidAll, 0.9))) px, max \(Self.fmt(euclidAll.max() ?? .nan)) px")
        print("[proto-detector] clutter pairs 16-19 detections: \(clutterDetections); wrong IDs anywhere: \(wrongIDs); detections without sub-pixel refinement: \(unrefined)")
        if !missedBig.isEmpty { print("[proto-detector] missed >= 24 px: \(missedBig)") }

        XCTAssertEqual(clutterDetections, 0, "no detections on clutter pairs")
        XCTAssertEqual(wrongIDs, 0, "no wrong IDs / misplaced detections")
        let big = try XCTUnwrap(recall["all>=24"])
        XCTAssertGreaterThanOrEqual(Double(big.found) / Double(big.total), 0.95, "recall for markers >= 24 px across")
        XCTAssertLessThan(Self.percentile(euclid, 0.9), 0.3, "corner p90 (>= 24 px markers)")
    }

    // MARK: - Corner order, mirror rejection

    func testCornerOrderFollowsPrintedOrientationUnderRotation() throws {
        let truth = try MarkerFixtureTests.loadTruth()[0].left
        let base = try Self.fixtureGray("left_0.png")
        for turns in 0..<4 {
            let (img, map) = Self.rotated(base, quarterTurns: turns)
            let found = detector.detectPixelMarkers(in: img)
            for t in truth where t.visible {
                let d = try XCTUnwrap(found.first { $0.id == t.id }, "id \(t.id) after \(turns * 90)°")
                for (k, c) in t.cornersPx.enumerated() {
                    XCTAssertLessThan(simd_distance(d.corners[k], map(c)), 1.0,
                                      "id \(t.id) corner \(k) after \(turns * 90)°")
                }
            }
        }
    }

    /// IDs 8 and 9 are symmetric about their main diagonal (transpose-invariant), so a mirrored 8 or 9 is bit-for-bit
    /// a rotated 8 or 9 — no detector can tell them apart. Only ID 7 is chiral. The test therefore requires that a
    /// mirrored 7 is rejected, and that mirrored 8/9 come back as an ordinary (clockwise-wound) physical marker.
    func testMirroredMarkerRejected() throws {
        func transposeSymmetric(_ b: [[Bool]]) -> Bool { (0..<4).allSatisfy { r in (0..<4).allSatisfy { b[r][$0] == b[$0][r] } } }
        XCTAssertFalse(transposeSymmetric(ArucoDictionary.markers[7]!))
        XCTAssertTrue(transposeSymmetric(ArucoDictionary.markers[8]!))
        XCTAssertTrue(transposeSymmetric(ArucoDictionary.markers[9]!))

        for index in [0, 1, 2] {
            for eye in ["left", "right"] {
                let g = try Self.fixtureGray("\(eye)_\(index).png")
                XCTAssertTrue(detector.detectPixelMarkers(in: g).contains { $0.id == 7 }, "sanity: unmirrored 7 found")
                let found = detector.detectPixelMarkers(in: Self.mirrored(g))
                XCTAssertFalse(found.contains { $0.id == 7 }, "mirrored ID 7 must be rejected (pair \(index) \(eye))")
                for d in found {
                    XCTAssertTrue([8, 9].contains(d.id))
                    let c = d.corners
                    var area2 = 0.0
                    for i in 0..<4 { let a = c[i], b = c[(i + 1) % 4]; area2 += a.x * b.y - b.x * a.y }
                    XCTAssertGreaterThan(area2, 0, "corners wound clockwise on screen like any real marker")
                }
            }
        }
    }

    // MARK: - Contract (normalized, top-left origin) through the protocol

    func testProtocolOutputIsNormalizedTopLeft() throws {
        let truth = try MarkerFixtureTests.loadTruth()[0].left
        let g = try Self.fixtureGray("left_0.png")
        let obs = try detector.detectMarkers(in: Self.cgImage(g))
        XCTAssertEqual(Set(obs.map(\.id)), Set(truth.filter(\.visible).map(\.id)))
        for o in obs {
            XCTAssertEqual(o.corners.count, 4)
            XCTAssertLessThanOrEqual(o.hammingDistance, 1)
            let t = truth.first { $0.id == o.id }!
            for (n, px) in zip(o.corners, t.cornersPx) {
                XCTAssertEqual(Double(n.x), (px.x + 0.5) / 480, accuracy: 1.0 / 480)
                XCTAssertEqual(Double(n.y), (px.y + 0.5) / 640, accuracy: 1.0 / 640)
            }
        }
    }

    // MARK: - Real glasses frames (report-only)

    func testRealSetupStillFramesReport() throws {
        guard FileManager.default.fileExists(atPath: Self.setupStill.path) else { throw XCTSkip("no setup-still frames") }
        var counts: [String: [Int: Int]] = ["left": [:], "right": [:]]
        var ms: [Double] = []
        var hamming = [0, 0]
        var images = 0, unrefined = 0
        var misses: [String] = []
        for n in 0..<60 {
            for eye in ["left", "right"] {
                let url = Self.setupStill.appendingPathComponent("\(eye)_\(n).png")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                // Decode the PNG up front and wrap the pixels like a live frame, so timing covers detection only
                // (plus the CGImage → gray copy), not PNG decompression.
                let gray = try XCTUnwrap(GrayImage(try Self.loadCG(url)))
                let img = Self.cgImage(gray)
                images += 1
                let t0 = DispatchTime.now().uptimeNanoseconds
                let obs = try detector.detectMarkers(in: img)
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                XCTAssertTrue(obs.allSatisfy { [7, 8, 9].contains($0.id) && $0.corners.count == 4 })
                XCTAssertEqual(Set(obs.map(\.id)).count, obs.count, "one detection per ID")
                let missing = Set([7, 8, 9]).subtracting(obs.map(\.id))
                if !missing.isEmpty { misses.append("\(eye)_\(n):\(missing.sorted())") }
                unrefined += detector.detect(gray).filter { !$0.refined }.count
                for o in obs {
                    counts[eye]![o.id, default: 0] += 1
                    hamming[min(o.hammingDistance, 1)] += 1
                    XCTAssertTrue(o.corners.allSatisfy { $0.x > 0 && $0.x < 1 && $0.y > 0 && $0.y < 1 })
                }
            }
        }
        XCTAssertEqual(images, 120)
        for id in [7, 8, 9] {
            print("[proto-detector] real setup-still id \(id): left \(counts["left"]![id] ?? 0)/60, right \(counts["right"]![id] ?? 0)/60")
        }
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        print("[proto-detector] real setup-still hamming 0: \(hamming[0]), hamming 1: \(hamming[1]); detections without sub-pixel refinement: \(unrefined)")
        print("[proto-detector] real setup-still misses: \(misses.joined(separator: " "))")
        print("[proto-detector] real setup-still ms per image (\(config), incl. CGImage→gray): median \(Self.fmt(Self.percentile(ms, 0.5), 2)), p90 \(Self.fmt(Self.percentile(ms, 0.9), 2))")
        let total = counts.values.flatMap(\.values).reduce(0, +)
        XCTAssertGreaterThan(total, 0, "sanity: something found on real frames")
    }

    // MARK: - Phone photo false-positive check

    func testPhonePhotoOnlyRealMarkers() throws {
        guard FileManager.default.fileExists(atPath: Self.phonePhoto.path) else { throw XCTSkip("IMG_3385.HEIC not present") }
        let img = try Self.loadCG(Self.phonePhoto, maxPixelSize: 1600)
        XCTAssertEqual(img.width, 1200); XCTAssertEqual(img.height, 1600)
        let expected: [SIMD2<Double>] = [SIMD2(520, 130), SIMD2(465, 1000), SIMD2(655, 975)]
        let t0 = DispatchTime.now().uptimeNanoseconds
        let obs = try detector.detectMarkers(in: img)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        var desc: [String] = []
        for o in obs {
            let c = o.corners.map { SIMD2(Double($0.x) * 1200 - 0.5, Double($0.y) * 1600 - 0.5) }
            let centre = c.reduce(SIMD2<Double>.zero, +) / 4
            let near = expected.map { simd_distance($0, centre) }.min()!
            desc.append("id \(o.id) at (\(Int(centre.x)),\(Int(centre.y))) h\(o.hammingDistance)")
            XCTAssertTrue([7, 8, 9].contains(o.id))
            XCTAssertLessThan(near, 80, "detection id \(o.id) at \(centre) is not on a real marker")
        }
        print("[proto-detector] IMG_3385 (1200x1600, \(Self.fmt(ms, 1)) ms): \(obs.count) detections: \(desc.joined(separator: ", "))")
    }
}
