import AppKit
import SwiftUI
import XRealVision

/// One camera pane. The image goes straight into the layer — no SwiftUI image diffing per frame. The hand overlay is a
/// subview pinned to the pane; it maps landmarks into the letterboxed image rect itself.
struct EyeView: NSViewRepresentable {
    let image: CGImage?
    var hands: EyeHands? = nil
    var fretboard: [FretboardProjection.Line] = []
    var fingertips: [FingertipMarks.Mark] = []

    func makeNSView(context: Context) -> EyeNSView {
        let v = EyeNSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resizeAspect
        v.fretOverlay.frame = v.bounds
        v.fretOverlay.autoresizingMask = [.width, .height]
        v.addSubview(v.fretOverlay)              // under the hand skeleton
        v.handOverlay.frame = v.bounds
        v.handOverlay.autoresizingMask = [.width, .height]
        v.addSubview(v.handOverlay)
        return v
    }

    func updateNSView(_ nsView: EyeNSView, context: Context) {
        nsView.layer?.contents = image
        nsView.fretOverlay.update(lines: fretboard, fingertips: fingertips)
        nsView.handOverlay.update(hands: hands)
    }
}

final class EyeNSView: NSView {
    let fretOverlay = FretboardOverlayNSView(frame: .zero)
    let handOverlay = HandOverlayNSView(frame: .zero)
}
