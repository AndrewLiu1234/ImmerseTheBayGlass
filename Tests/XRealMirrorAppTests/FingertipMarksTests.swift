import AppKit
import XCTest
import simd
@testable import XRealMirrorApp

/// Fingertip state colouring: each fingertip that's over the fretboard gets a ring in both eye panes (green filled =
/// pressing, yellow = hovering) and its 3-D sphere takes the same colour.
final class FingertipMarksTests: XCTestCase {
    let cal = StereoCalibration.xrealAir2Ultra

    private func placement(_ finger: FingerOnFretboard.Finger, tip: SIMD3<Double>, onNeck: Bool, pressing: Bool,
                           side: Hand3D.Side = .left) -> FingerPlacement {
        FingerPlacement(finger: finger, side: side, string: onNeck ? 1 : nil, stringName: onNeck ? "A" : nil,
                        fret: onNeck ? 2 : nil, height: pressing ? 0.008 : 0.03, onNeck: onNeck, pressing: pressing,
                        tip: tip)
    }

    func testMarksLandOnTheProjectedFingertipInEachEye() throws {
        let tip = SIMD3(0.05, 0.12, 0.32)
        let p = [placement(.index, tip: tip, onNeck: true, pressing: true)]
        let left = try XCTUnwrap(FingertipMarks.marks(p, eye: .left, calibration: cal).first)
        let right = try XCTUnwrap(FingertipMarks.marks(p, eye: .right, calibration: cal).first)
        let pl = try XCTUnwrap(cal.left.project(tip)), pr = try XCTUnwrap(cal.right.project(cal.leftToRight(tip)))
        XCTAssertEqual(Double(left.point.x) * 480 - 0.5, pl.x, accuracy: 0.01)
        XCTAssertEqual(Double(left.point.y) * 640 - 0.5, pl.y, accuracy: 0.01)
        XCTAssertEqual(Double(right.point.x) * 480 - 0.5, pr.x, accuracy: 0.01)
        XCTAssertNotEqual(left.point, right.point, "each eye sees the tip at its own position")
        XCTAssertEqual(left.state, .pressing)
    }

    func testOnlyFingertipsOverTheFretboardAreMarked() {
        let p = [placement(.index, tip: SIMD3(0, 0.1, 0.3), onNeck: true, pressing: true),
                 placement(.middle, tip: SIMD3(0.02, 0.1, 0.3), onNeck: true, pressing: false),
                 placement(.thumb, tip: SIMD3(0.04, 0.1, 0.3), onNeck: false, pressing: false)]
        let marks = FingertipMarks.marks(p, eye: .left, calibration: cal)
        XCTAssertEqual(marks.map(\.state), [.pressing, .hovering])
    }

    @MainActor
    func testOverlayDrawsAGreenFilledRingForPressing() throws {
        let size = CGSize(width: 600, height: 400)          // image rect x 150…450
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        window.contentView = container
        let overlay = FretboardOverlayNSView(frame: container.bounds)
        container.addSubview(overlay)
        overlay.update(lines: [], fingertips: [FingertipMarks.Mark(point: SIMD2(0.5, 0.5), state: .pressing),
                                               FingertipMarks.Mark(point: SIMD2(0.25, 0.25), state: .hovering)])
        window.displayIfNeeded()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try XCTUnwrap(container.layer).render(in: ctx)
        let img = try XCTUnwrap(ctx.makeImage()), d = try XCTUnwrap(img.dataProvider?.data) as Data
        func px(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let o = y * img.bytesPerRow + x * 4
            return (Int(d[o]), Int(d[o + 1]), Int(d[o + 2]), Int(d[o + 3]))
        }
        let centre = px(300, 200)                              // normalized (0.5, 0.5) → pane (300, 200): filled
        XCTAssertGreaterThan(centre.a, 0)
        XCTAssertGreaterThan(centre.g, centre.r + 40, "pressing is green")
        let hoverCentre = px(225, 100)                         // (0.25, 0.25) → (225, 100): a ring, so the centre is empty
        XCTAssertEqual(hoverCentre.a, 0, "hovering is an outline, not filled")
        overlay.update(lines: [], fingertips: [])
        XCTAssertTrue(overlay.layer?.sublayers?.compactMap { ($0 as? CAShapeLayer)?.path }.isEmpty ?? true,
                      "clearing removes the rings")
    }

    @MainActor
    func testFingertipSphereTakesTheStateColour() throws {
        let scene = Hands3DScene()
        var joints = [SIMD3<Double>](repeating: SIMD3(0, 0.15, 0.3), count: 21)
        joints[FingerOnFretboard.Finger.index.tipJoint] = SIMD3(0.02, 0.15, 0.3)
        let hand = Hand3D(joints: joints, meanRayGap: 0.005, side: .left, orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))
        scene.update([hand], placements: [placement(.index, tip: joints[8], onNeck: true, pressing: true)], timestamp: 0)
        XCTAssertEqual(scene.tipColor(side: .left, finger: .index), FingertipMarks.color(for: .pressing))
        XCTAssertEqual(scene.tipColor(side: .left, finger: .middle), Hands3DScene.color(for: .left), "untouched tips keep the hand colour")
        scene.update([hand], placements: [], timestamp: 1.0 / 30)
        XCTAssertEqual(scene.tipColor(side: .left, finger: .index), Hands3DScene.color(for: .left))
    }
}
