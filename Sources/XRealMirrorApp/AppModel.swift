import AppKit
import QuartzCore
import AVFoundation
import XRealVision

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum Status: Equatable { case searching, running, missing(String), permissionDenied }

    @Published var status: Status = .searching
    @Published var latestFrame: StereoFrame?
    /// Lags latestFrame by up to one tracker cycle (~33 ms): the overlay runs at 30 fps, the mirror at 60.
    @Published var latestHands: StereoHands?
    /// Hands triangulated from both eyes (left-camera frame, metres). Updated with latestHands at 30 fps.
    @Published var latestHands3D: [Hand3D] = []
    @Published var pairsPerSecond: Double = 0
    /// Fretboard stage: where the guitar is (nil = not seen), its lines projected into each eye, and where each
    /// fingertip is on it. Uses the NOMINAL F600 marker layout until a setup capture produces the real model.
    @Published var guitarPose: GuitarPose?
    @Published var fretLinesLeft: [FretboardProjection.Line] = []
    @Published var fretLinesRight: [FretboardProjection.Line] = []
    @Published var fingerPlacements: [FingerPlacement] = []
    @Published var fingertipMarksLeft: [FingertipMarks.Mark] = []
    @Published var fingertipMarksRight: [FingertipMarks.Mark] = []
    let fretboard = Fretboard(spec: .yamahaF600)

    /// A fresh StereoCamera per capture attempt: StereoCamera.stop() leaves the session's input/output attached,
    /// so start() on a stopped instance can't re-add them. A new instance always starts clean.
    private var camera: StereoCamera?
    /// Fresh tracker per capture attempt, same lifecycle as the camera.
    private var handTracker: StereoHandTracker?
    private let fusion = StereoHandFusion(calibration: .active)
    /// Person 1's marker tracker, running Person 1's MarkerDetector.
    private var markerTracker: StereoMarkerTracker?
    private let markerPoses = MarkerPoseEstimator(calibration: .active)
    private var guitarTracker = GuitarTracker(model: .nominalF600)
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
        handTracker?.delegate = nil
        handTracker = nil
        markerTracker?.delegate = nil
        markerTracker = nil
        rateTimer?.invalidate()
        rateTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func beginCapture() {
        stop()  // Retry/reconnect while running must not stack sessions or timers.
        latestFrame = nil
        latestHands = nil
        latestHands3D = []
        guitarTracker = GuitarTracker(model: guitarTracker.model)
        setGuitar(nil)
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
        let tracker = StereoHandTracker()
        tracker.delegate = self
        handTracker = tracker
        let markers = StereoMarkerTracker(detector: MarkerDetector())   // Person 1's detector (tracker default is a no-op)
        markers.delegate = self
        markerTracker = markers
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
            self.handTracker?.accept(box.frame)   // non-blocking enqueue (Lane 1 contract); detection runs off main
            self.markerTracker?.accept(box.frame) // same rules: O(1), latest-wins, every other pair
        }
    }
}

extension AppModel: StereoHandTrackerDelegate {
    // Called on the tracker's queue — hop to main, drop results from a tracker we've already replaced.
    nonisolated func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands) {
        let source = ObjectIdentifier(tracker)
        Task { @MainActor in
            guard let current = self.handTracker, ObjectIdentifier(current) == source else { return }
            self.latestHands = hands
            self.latestHands3D = self.fusion.fuse(hands)   // ≈0.3 ms: 42 ray solves
            self.updatePlacements()
        }
    }
}

extension AppModel: StereoMarkerTrackerDelegate {
    // Called on the marker tracker's queue — hop to main, drop results from a tracker we've already replaced.
    nonisolated func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers) {
        let source = ObjectIdentifier(tracker)
        Task { @MainActor in
            guard let current = self.markerTracker, ObjectIdentifier(current) == source else { return }
            let poses = self.markerPoses.estimate(left: markers.leftEye.markers, right: markers.rightEye.markers)
            self.setGuitar(self.guitarTracker.update(poses, timestamp: CACurrentMediaTime()))
        }
    }
}

extension AppModel {
    func setGuitar(_ pose: GuitarPose?) {
        guitarPose = pose
        if let pose {
            fretLinesLeft = FretboardProjection.lines(board: fretboard, pose: pose, eye: .left, calibration: .active)
            fretLinesRight = FretboardProjection.lines(board: fretboard, pose: pose, eye: .right, calibration: .active)
        } else {
            fretLinesLeft = []
            fretLinesRight = []
        }
        updatePlacements()
    }

    func updatePlacements() {
        guard let pose = guitarPose else {
            fingerPlacements = []; fingertipMarksLeft = []; fingertipMarksRight = []
            return
        }
        fingerPlacements = latestHands3D.flatMap { FingerOnFretboard.place(hand: $0, pose: pose, board: fretboard) }
            .filter(\.onNeck)
        fingertipMarksLeft = FingertipMarks.marks(fingerPlacements, eye: .left, calibration: .active)
        fingertipMarksRight = FingertipMarks.marks(fingerPlacements, eye: .right, calibration: .active)
    }
}
