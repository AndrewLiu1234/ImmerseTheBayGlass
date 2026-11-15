import CoreGraphics
import Foundation
import ImageIO
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 1. Regenerate the committed fixtures with:
///     GENERATE_MARKER_FIXTURES=1 swift test --filter MarkerFixtureTests/testGenerateFixtures
/// The other tests check the committed fixtures: ground truth is self-consistent and the rendered pixels agree with it.
final class MarkerFixtureTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/markers-synthetic")
    let cal = StereoCalibration.xrealAir2Ultra

    func testGenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["GENERATE_MARKER_FIXTURES"] != nil else {
            throw XCTSkip("set GENERATE_MARKER_FIXTURES=1 to regenerate fixtures/markers-synthetic")
        }
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let leftRays = MarkerFixtureRenderer.RayTable(lens: cal.left)
        let rightRays = MarkerFixtureRenderer.RayTable(lens: cal.right)
        var rng = SplitMix64(state: 0xF600)
        var pairs: [FixturePair] = []

        for index in 0..<20 {
            let kind = index < 8 ? "frontal" : (index < 16 ? "playing" : "clutter")
            var r = matrix_identity_double3x3, t = SIMD3<Double>.zero
            if kind == "frontal" {
                // Facing the camera like IMG_3385 (neck up, treble on the right), 35–90 cm, tilted up to 40°, rolled.
                let k = Double(index)
                let pos = SIMD3(rng.uniform(-0.08...0.08), rng.uniform(-0.06...0.06), 0.35 + 0.08 * k)
                var n = -simd_normalize(pos)
                let tiltAxis = simd_normalize(simd_cross(n, SIMD3(rng.uniform(-1...1), rng.uniform(-1...1), 0.2)))
                n = MarkerFixtureRenderer.rotate(n, axis: tiltAxis, angle: rng.uniform(0...0.7))
                let xHint = MarkerFixtureRenderer.rotate(SIMD3(0, 1, 0), axis: SIMD3(0, 0, 1), angle: rng.uniform(-1.6...1.6))
                (r, t) = MarkerFixtureRenderer.pose(anchor: SIMD3(0.2, 0, 0), position: pos, normal: n, xHint: xHint)
            } else if kind == "playing" {
                // The player's own view: body below/in front, neck to the left, top tilted up — markers seen at
                // 50–78° incidence (the realistic hard case).
                let pos = SIMD3(rng.uniform(-0.04...0.10), rng.uniform(0.16...0.28), rng.uniform(0.24...0.40))
                let n0 = -simd_normalize(pos)
                let alpha = rng.uniform(50...78) * .pi / 180
                let n = MarkerFixtureRenderer.rotate(n0, axis: simd_cross(n0, SIMD3(0, -1, 0)), angle: alpha)
                (r, t) = MarkerFixtureRenderer.pose(anchor: SIMD3(FixtureGuitar.fret14, 0, 0), position: pos, normal: n,
                                                    xHint: SIMD3(1, rng.uniform(-0.1...0.3), 0))
            }
            let markersL = kind == "clutter" ? [] : FixtureGuitar.markers.map { $0.transformed(r, t) }
            let surfL = kind == "clutter" ? [] : FixtureGuitar.surfaces.map { s in
                (c: r * s.c + t, a: r * s.a, b: r * s.b, ha: s.ha, hb: s.hb, albedo: s.albedo)
            }
            let markersR = markersL.map { $0.transformed(cal.rotation, cal.translation) }
            let surfR = surfL.map { s in
                (c: cal.leftToRight(s.c), a: cal.rotation * s.a, b: cal.rotation * s.b, ha: s.ha, hb: s.hb, albedo: s.albedo)
            }
            let exposure = rng.uniform(0.8...1.1)
            let seed = UInt64(index) &* 7919
            let left = MarkerFixtureRenderer.renderEye(rays: leftRays, markers: markersL, surfaces: surfL,
                                                       clutterSeed: seed, exposure: exposure, noiseSeed: seed &+ 1)
            let right = MarkerFixtureRenderer.renderEye(rays: rightRays, markers: markersR, surfaces: surfR,
                                                        clutterSeed: seed &+ 2, exposure: exposure, noiseSeed: seed &+ 3)
            try MarkerFixtureRenderer.writePNG(left, to: Self.dir.appendingPathComponent("left_\(index).png"))
            try MarkerFixtureRenderer.writePNG(right, to: Self.dir.appendingPathComponent("right_\(index).png"))
            pairs.append(FixturePair(
                index: index, kind: kind,
                guitarRotation: kind == "clutter" ? nil : [r.columns.0, r.columns.1, r.columns.2],
                guitarTranslation: kind == "clutter" ? nil : t,
                markers: markersL,
                left: MarkerFixtureRenderer.eyeTruth(markersL, lens: cal.left, toEye: { $0 }, eyeRotation: matrix_identity_double3x3),
                right: MarkerFixtureRenderer.eyeTruth(markersL, lens: cal.right, toEye: { self.cal.leftToRight($0) },
                                                      eyeRotation: cal.rotation)))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(pairs).write(to: Self.dir.appendingPathComponent("truth.json"))
    }

    static func loadTruth() throws -> [FixturePair] {
        try JSONDecoder().decode([FixturePair].self, from: Data(contentsOf: dir.appendingPathComponent("truth.json")))
    }

    static func loadGray(_ name: String) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: img.width * img.height)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (px, img.width, img.height)
    }

    /// The fixtures' copy of the bit patterns must equal Person 1's ArucoDictionary (both come from the PDFs).
    func testFixturePatternsMatchPerson1sDictionary() {
        for id in TestMarkerPatterns.ids {
            let mine = TestMarkerPatterns.bits[id]!.map { row in row.map { $0 == "1" } }
            XCTAssertEqual(ArucoDictionary.markers[id], mine, "ID \(id)")
        }
        XCTAssertEqual(Set(ArucoDictionary.markers.keys), [7, 8, 9])
    }

    func testFixtureSetIsCompleteAndCoversTheCases() throws {
        let pairs = try Self.loadTruth()
        XCTAssertEqual(pairs.count, 20)
        for p in pairs {
            for eye in ["left", "right"] {
                let g = try Self.loadGray("\(eye)_\(p.index).png")
                XCTAssertEqual(g.width, 480); XCTAssertEqual(g.height, 640)
            }
        }
        let visible = pairs.flatMap { $0.left + $0.right }.filter(\.visible)
        XCTAssertGreaterThan(visible.count, 40, "enough visible marker views to test a detector")
        XCTAssertTrue(visible.contains { $0.incidenceDeg > 55 }, "grazing (playing-pose) views are included")
        XCTAssertTrue(pairs.filter { $0.kind == "clutter" }.allSatisfy { $0.markers.isEmpty })
    }

    func testFixtureCornersReprojectFromTruthPose() throws {
        for p in try Self.loadTruth() {
            for m in p.markers {
                let cs = m.corners()
                let l = try XCTUnwrap(p.left.first { $0.id == m.id }), r = try XCTUnwrap(p.right.first { $0.id == m.id })
                for k in 0..<4 {
                    if let pl = cal.left.project(cs[k]) { XCTAssertLessThan(simd_distance(pl, l.cornersPx[k]), 0.01) }
                    if let pr = cal.right.project(cal.leftToRight(cs[k])) { XCTAssertLessThan(simd_distance(pr, r.cornersPx[k]), 0.01) }
                }
                XCTAssertEqual(simd_distance(cs[0], cs[1]), 0.060, accuracy: 1e-9)
            }
        }
    }

    /// The pixels agree with the truth: inside each visible black square near its border it's dark; just outside it
    /// (on the paper quiet zone) it's clearly brighter. Catches a renderer/truth mismatch (flip, mirror, offset).
    /// One corner per marker may fail the "outside" check: the body papers tuck under the neck's edge.
    func testRenderedPixelsMatchTheTruthCorners() throws {
        var checked = 0
        for p in try Self.loadTruth() {
            for (eye, truths) in [("left", p.left), ("right", p.right)] {
                let g = try Self.loadGray("\(eye)_\(p.index).png")
                for t in truths where t.visible && t.incidenceDeg < 60 {
                    let c = t.cornersPx, mid = (c[0] + c[1] + c[2] + c[3]) / 4
                    guard simd_distance(c[0], c[2]) > 30 else { continue }   // big enough to sample cleanly
                    func at(_ q: SIMD2<Double>) -> Int { Int(g.pixels[Int(q.y.rounded()) * g.width + Int(q.x.rounded())]) }
                    var brighterOutside = 0
                    for k in 0..<4 {
                        let inside = mid + (c[k] - mid) * 0.88        // within the black border cell
                        let outside = mid + (c[k] - mid) * 1.25       // on the white paper
                        XCTAssertLessThan(at(inside), 90, "\(eye)_\(p.index) id \(t.id) corner \(k) should be black")
                        if at(outside) > at(inside) + 40 { brighterOutside += 1 }
                    }
                    XCTAssertGreaterThanOrEqual(brighterOutside, 3, "\(eye)_\(p.index) id \(t.id): paper missing around the square")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }
}
