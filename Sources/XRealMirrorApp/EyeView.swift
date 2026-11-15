import AppKit
import SwiftUI
import XRealVision

/// One camera pane. The image goes straight into the layer — no SwiftUI image diffing per frame. The hand overlay is a
/// subview pinned to the pane; it maps landmarks into the letterboxed image rect itself.
struct EyeView: NSViewRepresentable {
    let image: CGImage?
    var hands: EyeHands? = nil

    func makeNSView(context: Context) -> EyeNSView {
        let v = EyeNSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resizeAspect
        v.handOverlay.frame = v.bounds
        v.handOverlay.autoresizingMask = [.width, .height]
        v.addSubview(v.handOverlay)
        return v
    }

    func updateNSView(_ nsView: EyeNSView, context: Context) {
        nsView.layer?.contents = image
        nsView.handOverlay.update(hands: hands)
    }
}

final class EyeNSView: NSView {
    let handOverlay = HandOverlayNSView(frame: .zero)
}
