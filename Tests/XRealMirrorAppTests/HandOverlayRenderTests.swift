import AppKit
import XCTest
import XRealVision
@testable import XRealMirrorApp

/// Renders the real overlay view and finds where its pixels land. Pins the two traps pure math can't: the overlay
/// being upside down (layer orientation) and drawn over the pane instead of the letterboxed image.
@MainActor
final class HandOverlayRenderTests: XCTestCase {
    private let paneSize = CGSize(width: 600, height: 400)   // wide pane → 480x640 image letterboxed to 300x400

    private func hand(_ chirality: HandChirality, at p: SIMD2<Float>) -> TrackedHand {
        TrackedHand(landmarks: [SIMD2<Float>](repeating: p, count: 21),
                    confidences: [Float](repeating: 1, count: 21), chirality: chirality)
    }

    /// Returns the bounding box (top-left origin, points) of all non-transparent pixels the overlay drew.
    private func drawnBox(_ hands: EyeHands?) throws -> CGRect? {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: paneSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(origin: .zero, size: paneSize))
        container.wantsLayer = true
        window.contentView = container
        let overlay = HandOverlayNSView(frame: container.bounds)
        container.addSubview(overlay)
        container.layoutSubtreeIfNeeded()
        overlay.update(hands: hands, timestamp: 0)
        window.displayIfNeeded()   // AppKit attaches subview layers to the window's tree on display
        XCTAssertTrue(overlay.layer?.superlayer === container.layer, "overlay layer not composited into the pane")

        let w = Int(paneSize.width), h = Int(paneSize.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Render the pane's whole layer tree, as composited on screen (includes AppKit's flip for isFlipped views).
        try XCTUnwrap(container.layer).render(in: ctx)
        let image = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        var box: CGRect?
        for row in 0..<h {            // CGImage row 0 is the TOP of the image
            for col in 0..<w where data[row * image.bytesPerRow + col * 4 + 3] > 0 {
                let px = CGRect(x: col, y: row, width: 1, height: 1)
                box = box.map { $0.union(px) } ?? px
            }
        }
        return box
    }

    func testNoHandsDrawsNothing() throws {
        XCTAssertNil(try drawnBox(nil))
        XCTAssertNil(try drawnBox(EyeHands()))
    }

    func testTopLeftLandmarkRendersAtTopLeftOfImageRect() throws {
        // Image rect inside the 600x400 pane: x 150...450, y 0...400. Landmark (0.1, 0.1) → (180, 40), top-left.
        let box = try XCTUnwrap(try drawnBox(EyeHands(hands: [hand(.right, at: SIMD2(0.1, 0.1))])))
        XCTAssertEqual(box.midX, 180, accuracy: 2, "x must go through the letterbox rect, not the pane")
        XCTAssertEqual(box.midY, 40, accuracy: 2, "y must be top-down (contract origin top-left), not flipped")
    }

    func testBottomRightLandmarkRendersAtBottomRight() throws {
        let box = try XCTUnwrap(try drawnBox(EyeHands(hands: [hand(.left, at: SIMD2(0.9, 0.9))])))
        XCTAssertEqual(box.midX, 420, accuracy: 2)
        XCTAssertEqual(box.midY, 360, accuracy: 2)
    }

    func testHandsGetTheirChiralityColors() {
        XCTAssertNotEqual(HandOverlayNSView.color(for: .left), HandOverlayNSView.color(for: .right))
        XCTAssertNotEqual(HandOverlayNSView.color(for: .unknown), HandOverlayNSView.color(for: .right))
    }
}

@MainActor
final class HandOverlayUpdateTests: XCTestCase {
    func testRepeatedInputDoesNotStepTheFilter() throws {
        let overlay = HandOverlayNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 640))
        func hand(_ x: Float) -> EyeHands {
            EyeHands(hands: [TrackedHand(landmarks: [SIMD2<Float>](repeating: SIMD2(x, 0.5), count: 21),
                                         confidences: [Float](repeating: 1, count: 21), chirality: .right)])
        }
        func dotX() throws -> CGFloat {
            let dots = try XCTUnwrap(overlay.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.fillColor != nil && $0.path != nil })
            return try XCTUnwrap(dots.path).boundingBox.midX
        }
        overlay.update(hands: hand(0.0), timestamp: 0)
        overlay.update(hands: hand(1.0), timestamp: 1.0 / 30)
        let afterStep = try dotX()
        overlay.update(hands: hand(1.0), timestamp: 1.5 / 30)   // same result again at the 60 fps refresh
        XCTAssertEqual(try dotX(), afterStep, accuracy: 0.0001, "identical input must not advance smoothing")
        overlay.update(hands: EyeHands(), timestamp: 2.0 / 30)
        XCTAssertTrue(overlay.layer?.sublayers?.compactMap { ($0 as? CAShapeLayer)?.path }.isEmpty ?? false)
    }
}
