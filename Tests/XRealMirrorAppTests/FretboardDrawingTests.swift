import AppKit
import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 7: fretboard lines projected into each eye (2-D overlay) and placed in the 3-D pane.
final class FretboardDrawingTests: XCTestCase {
    let cal = StereoCalibration.xrealAir2Ultra
    let board = Fretboard(spec: .yamahaF600)

    private func truthPose(_ p: FixturePair) -> GuitarPose {
        let c = p.guitarRotation!
        return GuitarPose(rotation: simd_double3x3(columns: (c[0], c[1], c[2])), translation: p.guitarTranslation!,
                          markersUsed: [7, 8, 9], residualRMS: 0, state: .tracking)
    }

    /// Independent cross-check against the fixture generator: projecting the fixture guitar's marker corners with the
    /// true guitar pose must land on truth.json's corner pixels in BOTH eyes (eye transform + pixel convention).
    func testProjectionAgreesWithTheFixtureTruthInBothEyes() throws {
        var checked = 0
        for p in try MarkerFixtureTests.loadTruth() where p.kind != "clutter" {
            let pose = truthPose(p)
            for m in FixtureGuitar.markers {
                for (eye, truths) in [(FretboardProjection.Eye.left, p.left), (.right, p.right)] {
                    let t = try XCTUnwrap(truths.first { $0.id == m.id })
                    guard t.visible else { continue }
                    for k in 0..<4 {
                        let n = try XCTUnwrap(FretboardProjection.project(m.corners()[k], pose: pose, eye: eye, calibration: cal))
                        let px = SIMD2(Double(n.x) * 480 - 0.5, Double(n.y) * 640 - 0.5)
                        XCTAssertLessThan(simd_distance(px, t.cornersPx[k]), 0.01, "pair \(p.index) id \(m.id) \(eye) corner \(k)")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    /// Tasks 3 + 5 + 7 together on the fixtures: detected corners (0.15 px noise) → marker poses → guitar pose →
    /// fretboard points, compared with the true guitar pose.
    func testEndToEndFromFixtureCornersToTheFretboard() throws {
        let model = GuitarTrackerTests.model
        var errors: [Double] = []
        for p in try MarkerFixtureTests.loadTruth() where p.kind != "clutter" {
            var rng = SplitMix64(state: UInt64(p.index) + 100)
            func obs(_ ts: [FixturePair.EyeTruth]) -> [MarkerObservation] {
                ts.filter(\.visible).map { t in
                    MarkerObservation(id: t.id, corners: t.cornersPx.map { c in
                        let q = c + 0.15 * SIMD2(rng.gaussian(), rng.gaussian())
                        return SIMD2(Float((q.x + 0.5) / 480), Float((q.y + 0.5) / 640))
                    }, hammingDistance: 0)
                }
            }
            let poses = MarkerPoseEstimator(calibration: cal).estimate(left: obs(p.left), right: obs(p.right))
            var tracker = GuitarTracker(model: model, smoothing: false)
            guard let g = tracker.update(poses, timestamp: 0) else { XCTFail("no guitar pose for pair \(p.index)"); continue }
            let truth = truthPose(p)
            errors.append(GuitarTestSupport.fingeringPoints.map { simd_distance(g.toCamera($0), truth.toCamera($0)) }.max()!)
        }
        errors.sort()
        print(String(format: "[fretboard-e2e] %d pairs: fingering-area error median %.2f mm, max %.2f mm",
                     errors.count, errors[errors.count / 2] * 1000, errors.last! * 1000))
        XCTAssertEqual(errors.count, 16)
        XCTAssertLessThan(errors[errors.count / 2], 0.003)
    }

    func testLinesCoverNutFretsStringsAndEdges() throws {
        let p = try XCTUnwrap(try MarkerFixtureTests.loadTruth().first { $0.kind == "frontal" })
        let lines = FretboardProjection.lines(board: board, pose: truthPose(p), eye: .left, calibration: cal)
        XCTAssertEqual(lines.filter { $0.kind == .nut }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .fret }.count, board.spec.fretCount)
        XCTAssertEqual(lines.filter { $0.kind == .string }.count, 6)
        XCTAssertEqual(lines.filter { $0.kind == .edge }.count, 2)
        for l in lines { XCTAssertTrue(l.segments.allSatisfy { $0.count >= 2 }) }
        // Strings are sampled finely enough to show the fisheye curve.
        XCTAssertGreaterThan(lines.first { $0.kind == .string }!.segments.flatMap { $0 }.count, 20)
    }

    func testLinesBreakWhereTheyLeaveTheView() {
        // Guitar straddling the camera plane: part of it is behind the glasses.
        let pose = GuitarPose(rotation: simd_double3x3(simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))),
                              translation: SIMD3(0, 0.1, 0.15), markersUsed: [], residualRMS: 0, state: .tracking)
        let lines = FretboardProjection.lines(board: board, pose: pose, eye: .left, calibration: cal)
        for l in lines {
            for seg in l.segments {
                for q in seg { XCTAssertTrue((-0.25...1.25).contains(q.x) && (-0.25...1.25).contains(q.y), "no wild points") }
            }
        }
        let strings = lines.filter { $0.kind == .string }
        XCTAssertTrue(strings.allSatisfy { $0.segments.flatMap { $0 }.count < 64 }, "points behind the camera are dropped")
    }

    func testNominalModelHasAllThreeMarkersOnTheRightSides() {
        let m = GuitarModel.nominalF600
        let c7 = m.corners(of: 7)!.reduce(.zero, +) / 4, c8 = m.corners(of: 8)!.reduce(.zero, +) / 4
        let c9 = m.corners(of: 9)!.reduce(.zero, +) / 4
        XCTAssertGreaterThan(c7.y, 0, "ID 7 treble")
        XCTAssertLessThan(c8.y, 0, "ID 8 bass")
        XCTAssertLessThan(c9.x, 0, "ID 9 on the headstock, beyond the nut")
        XCTAssertEqual(c7.x, board.fretX(14), accuracy: 0.001)
    }

    @MainActor
    func testOverlayDrawsLinesInsideTheLetterboxedImage() throws {
        let size = CGSize(width: 600, height: 400)            // 480x640 image letterboxed to x 150…450
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        window.contentView = container
        let overlay = FretboardOverlayNSView(frame: container.bounds)
        container.addSubview(overlay)
        overlay.update(lines: [FretboardProjection.Line(kind: .nut, segments: [[SIMD2(0.25, 0.1), SIMD2(0.75, 0.1)]])])
        window.displayIfNeeded()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try XCTUnwrap(container.layer).render(in: ctx)
        let img = try XCTUnwrap(ctx.makeImage()), data = try XCTUnwrap(img.dataProvider?.data) as Data
        var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
        for y in 0..<400 { for x in 0..<600 where data[y * img.bytesPerRow + x * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        // Normalized (0.25…0.75, 0.1) → x 225…375, y 40 inside the image rect.
        XCTAssertEqual(Double(minX), 225, accuracy: 3); XCTAssertEqual(Double(maxX), 375, accuracy: 3)
        XCTAssertEqual(Double(minY + maxY) / 2, 40, accuracy: 2)
        overlay.update(lines: [])
        XCTAssertTrue(overlay.layer?.sublayers?.compactMap { ($0 as? CAShapeLayer)?.path }.isEmpty ?? true)
    }

    @MainActor
    func testGuitarNodeFollowsThePoseIn3D() {
        let scene = Hands3DScene()
        let pose = GuitarPose(rotation: simd_double3x3(simd_quatd(angle: 0.7, axis: SIMD3(0, 0, 1))),
                              translation: SIMD3(0.05, 0.2, 0.35), markersUsed: [7], residualRMS: 0, state: .tracking)
        scene.update(guitar: pose, board: board)
        let nutInScene = scene.guitarNode.simdConvertPosition(SIMD3<Float>(0, 0, 0), to: nil)
        XCTAssertLessThan(simd_distance(nutInScene, Hands3DScene.scenePoint(pose.toCamera(.zero))), 1e-5)
        let fret12 = SIMD3(board.fretX(12), 0, 0)
        XCTAssertLessThan(simd_distance(scene.guitarNode.simdConvertPosition(SIMD3<Float>(fret12), to: nil),
                                        Hands3DScene.scenePoint(pose.toCamera(fret12))), 1e-5)
        XCTAssertFalse(scene.guitarNode.isHidden)
        scene.update(guitar: nil, board: board)
        XCTAssertTrue(scene.guitarNode.isHidden)
    }
}
