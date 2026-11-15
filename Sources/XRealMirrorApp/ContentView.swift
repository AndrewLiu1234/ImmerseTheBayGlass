import SwiftUI
import XRealVision

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                EyeView(image: model.latestFrame?.left.image, hands: model.latestHands?.leftEye)
                    .overlay(alignment: .topLeading) { paneLabel("LEFT · 0x20") }
                EyeView(image: model.latestFrame?.right.image, hands: model.latestHands?.rightEye)
                    .overlay(alignment: .topLeading) { paneLabel("RIGHT · 0x21") }
            }
            .overlay {
                if model.latestFrame == nil && model.status == .running {
                    Text("Waiting for frames…").foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                statusDot(model.status)
                Text(statusText(model.status))
                Spacer()
                if model.status == .running {
                    Text(String(format: "%.1f pairs/s", model.pairsPerSecond)).monospacedDigit()
                }
                Button("Retry") { model.start() }.keyboardShortcut("r")
            }
            .padding(8)
        }
        .frame(minWidth: 960, minHeight: 420)
        .overlay { missingOverlay(model.status) }
        .onAppear { model.start() }
    }

    private func paneLabel(_ s: String) -> some View {
        Text(s).font(.caption.monospaced().bold()).padding(6)
            .background(.black.opacity(0.6)).foregroundStyle(.white)
    }

    private func statusDot(_ s: AppModel.Status) -> some View {
        let color: Color
        switch s {
        case .running: color = .green
        case .searching: color = .yellow
        case .missing, .permissionDenied: color = .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func statusText(_ s: AppModel.Status) -> String {
        switch s {
        case .searching: return "Looking for XREAL Air 2 Ultra…"
        case .running: return "Running"
        case .missing(let reason): return reason
        case .permissionDenied:
            return "Camera permission denied — enable XRealMirror in System Settings → Privacy & Security → Camera, then Retry."
        }
    }

    @ViewBuilder private func missingOverlay(_ s: AppModel.Status) -> some View {
        if case .missing = s {
            VStack(spacing: 12) {
                Image(systemName: "eyeglasses").font(.largeTitle)
                Text("XREAL Air 2 Ultra not found").font(.title2.bold())
                Text(statusText(s)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { model.start() }.buttonStyle(.borderedProminent)
            }
            .padding(40).frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}
