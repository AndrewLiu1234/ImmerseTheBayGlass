import SceneKit
import SwiftUI

/// The live 3-D hands pane. Drag to orbit, scroll/pinch to zoom, double-click to reset the view.
struct Hands3DView: NSViewRepresentable {
    let hands: [Hand3D]
    var guitar: GuitarPose? = nil
    var placements: [FingerPlacement] = []
    var board = Fretboard(spec: .yamahaF600)

    @MainActor final class Coordinator {
        let content = Hands3DScene()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.content.scene
        v.pointOfView = context.coordinator.content.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.target = SCNVector3(0.07, -0.15, -0.25)
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .black
        v.rendersContinuously = false   // redraws on scene changes (30 fps hand updates) and on interaction
        return v
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.content.update(hands, placements: placements)
        context.coordinator.content.update(guitar: guitar, board: board)
    }
}

/// Text readout for the 3-D pane: where each hand's wrist is relative to the glasses.
struct Hands3DReadout: View {
    let hands: [Hand3D]
    var guitar: GuitarPose? = nil
    var placements: [FingerPlacement] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hands.isEmpty {
                Text("No hand seen by both cameras")
            }
            ForEach(Array(hands.enumerated()), id: \.offset) { _, h in
                Text(line(h)).foregroundStyle(Color(nsColor: Hands3DScene.color(for: h.side)))
            }
            Text(guitarLine).foregroundStyle(guitar == nil ? Color.secondary : Color.green)
            ForEach(Array(placements.enumerated()), id: \.offset) { _, p in
                Text("\(p.side == .left ? "L" : "R") \(p.summary)")
                    .foregroundStyle(Color(nsColor: Hands3DScene.color(for: p.side)))
            }
        }
        .font(.caption.monospaced())
        .padding(6)
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
    }

    private var guitarLine: String {
        guard let g = guitar else { return "Guitar: not seen (markers 7/8/9)" }
        let ids = g.markersUsed.map(String.init).joined(separator: ",")
        return g.state == .holding ? "Guitar: holding last pose" : "Guitar: tracking (markers \(ids))"
    }

    private func line(_ h: Hand3D) -> String {
        let w = h.wrist * 100   // cm; camera frame: x right, y down, z ahead
        return String(format: "%@ wrist  %4.0f cm ahead  %+4.0f cm %@  %4.0f cm %@  ±%.0f mm",
                      h.side == .left ? "L" : "R", w.z, abs(w.x), w.x < 0 ? "left " : "right",
                      abs(w.y), w.y > 0 ? "down" : "up  ", h.meanRayGap * 1000)
    }
}
