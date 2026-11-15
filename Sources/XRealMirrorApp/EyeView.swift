import AppKit
import SwiftUI

/// One camera pane. The image goes straight into the layer — no SwiftUI image diffing per frame.
struct EyeView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> EyeNSView {
        let v = EyeNSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: EyeNSView, context: Context) {
        nsView.layer?.contents = image
    }
}

final class EyeNSView: NSView {}
