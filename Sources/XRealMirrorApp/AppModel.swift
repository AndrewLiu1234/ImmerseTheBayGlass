import AppKit
import AVFoundation
import XRealVision

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum Status: Equatable { case searching, running, missing(String), permissionDenied }

    @Published var status: Status = .searching
    @Published var latestFrame: StereoFrame?
    @Published var pairsPerSecond: Double = 0

    /// A fresh StereoCamera per capture attempt: StereoCamera.stop() leaves the session's input/output attached,
    /// so start() on a stopped instance can't re-add them. A new instance always starts clean.
    private var camera: StereoCamera?
    private var pairCounter = 0
    private var silentSeconds = 0
    private var rateTimer: Timer?
    private var retryTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private static let notFound = "No XREAL Air 2 Ultra found. Plug in the glasses via USB-C — the app reconnects on its own."
    /// Running with zero pairs for this long (glasses mode-flapping, USB hiccup) → restart capture.
    private static let stallSeconds = 3

    func start() {
        observeDevices()
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
        camera?.stop()
        camera = nil
        rateTimer?.invalidate()
        rateTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func beginCapture() {
        stop()  // Retry/reconnect while running must not stack sessions or timers.
        latestFrame = nil
        pairCounter = 0
        silentSeconds = 0
        pairsPerSecond = 0
        guard StereoCamera.findXRealDevice() != nil else { return markMissing(Self.notFound) }
        let cam = StereoCamera()
        cam.delegate = self
        do {
            try cam.start()
        } catch XRealCameraError.deviceNotFound {
            return markMissing(Self.notFound)
        } catch {
            return markMissing("Could not start the XREAL camera: \(error.localizedDescription)")
        }
        camera = cam
        status = .running
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRate() }
        }
    }

    private func tickRate() {
        pairsPerSecond = Double(pairCounter)
        silentSeconds = pairCounter == 0 ? silentSeconds + 1 : 0
        pairCounter = 0
        if status == .running && silentSeconds >= Self.stallSeconds {
            beginCapture()  // stalled: restart (falls back to .missing + auto-retry if the device is gone)
        }
    }

    /// Shows the not-found state and polls for the glasses every 2 s, so a re-plug recovers without a click.
    private func markMissing(_ reason: String) {
        stop()
        status = .missing(reason)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .missing = self.status, StereoCamera.findXRealDevice() != nil else { return }
                self.beginCapture()
            }
        }
    }

    /// Hot-plug: react immediately to USB connect/disconnect (the 2 s poll is the backstop).
    private func observeDevices() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if case .missing = self.status, StereoCamera.findXRealDevice() != nil { self.beginCapture() }
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if self.status == .running, StereoCamera.findXRealDevice() == nil { self.markMissing(Self.notFound) }
            }
        })
    }
}

/// Carries a frame from the capture queue to the main actor. StereoFrame holds only immutable CGImages and values.
private struct FrameBox: @unchecked Sendable { let frame: StereoFrame }

extension AppModel: StereoCameraDelegate {
    // Called on the camera's capture queue — hop to main for UI. Frames from a camera we've already replaced are dropped.
    nonisolated func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame) {
        let box = FrameBox(frame: frame)
        let source = ObjectIdentifier(camera)
        Task { @MainActor in
            guard let current = self.camera, ObjectIdentifier(current) == source else { return }
            self.latestFrame = box.frame
            self.pairCounter += 1
        }
    }
}
