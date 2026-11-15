import AppKit
import AVFoundation
import XRealVision

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum Status: Equatable { case searching, running, missing(String), permissionDenied }

    @Published var status: Status = .searching
    @Published var latestFrame: StereoFrame?
    @Published var pairsPerSecond: Double = 0

    private let camera = StereoCamera()
    private var pairCounter = 0
    private var rateTimer: Timer?

    func start() {
        status = .searching
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.beginCapture() } else { self.status = .permissionDenied }
                }
            }
        case .denied, .restricted:
            status = .permissionDenied
        @unknown default:
            status = .permissionDenied
        }
    }

    func stop() {
        camera.stop()
        rateTimer?.invalidate()
        rateTimer = nil
    }

    private func beginCapture() {
        stop()  // Retry while running must not stack sessions or timers.
        latestFrame = nil
        pairCounter = 0
        pairsPerSecond = 0
        guard StereoCamera.findXRealDevice() != nil else {
            status = .missing("No XREAL Air 2 Ultra found. Plug in the glasses via USB-C, then Retry.")
            return
        }
        camera.delegate = self
        do {
            try camera.start()
            status = .running
            rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pairsPerSecond = Double(self.pairCounter)
                    self.pairCounter = 0
                }
            }
        } catch XRealCameraError.deviceNotFound {
            status = .missing("No XREAL Air 2 Ultra found. Plug in the glasses via USB-C, then Retry.")
        } catch {
            status = .missing("Could not start the XREAL camera: \(error.localizedDescription)")
        }
    }
}

/// Carries a frame from the capture queue to the main actor. StereoFrame holds only immutable CGImages and values.
private struct FrameBox: @unchecked Sendable { let frame: StereoFrame }

extension AppModel: StereoCameraDelegate {
    // Called on the camera's capture queue — hop to main for UI.
    nonisolated func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame) {
        let box = FrameBox(frame: frame)
        Task { @MainActor in
            self.latestFrame = box.frame
            self.pairCounter += 1
        }
    }
}
