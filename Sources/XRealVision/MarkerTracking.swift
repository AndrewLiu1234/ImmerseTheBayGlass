import CoreGraphics
import Foundation
import simd

/// One decoded ArUco marker seen by one eye.
public struct MarkerObservation: Sendable {
    public var id: Int                       // 7, 8 or 9
    public var corners: [SIMD2<Float>]       // exactly 4, normalized 0...1, origin TOP-LEFT of the upright image,
                                             // ArUco order: the printed marker's top-left, top-right, bottom-right,
                                             // bottom-left (so orientation survives rotation of the guitar)
    public var hammingDistance: Int          // bits corrected when decoding (0 = exact)
    public init(id: Int, corners: [SIMD2<Float>], hammingDistance: Int) {
        self.id = id
        self.corners = corners
        self.hammingDistance = hammingDistance
    }
}

/// Markers seen by one eye in one frame. Empty means "no markers" — normal, not an error.
public struct EyeMarkers: Sendable {
    public var markers: [MarkerObservation]

    public init(markers: [MarkerObservation] = []) {
        self.markers = markers
    }
}

/// Both eyes' markers for one processed frame pair, plus the source frame's identity.
public struct StereoMarkers: Sendable {
    public var leftEye: EyeMarkers
    public var rightEye: EyeMarkers
    public var sequence: UInt16
    public var timestampMicros: UInt64

    // PUBLIC init: stage 2's StereoHands lacked one, which blocked app-side tests.
    public init(leftEye: EyeMarkers, rightEye: EyeMarkers, sequence: UInt16, timestampMicros: UInt64) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.sequence = sequence
        self.timestampMicros = timestampMicros
    }
}

/// The printed 4×4 ArUco dictionary (OpenCV `DICT_4X4_50` IDs 7, 8, 9). Rows top→bottom
/// as printed upright, `true` = white. Pinned by `ArucoDictionaryTests` against the printed
/// PDFs — if a pattern disagrees with a printout, STOP and report, never edit it to pass.
public enum ArucoDictionary {
    public static let markers: [Int: [[Bool]]] = [
        7: [
            [true, true, false, false],
            [false, true, false, false],
            [true, true, true, true],
            [false, false, true, false],
        ],
        8: [
            [true, true, true, true],
            [true, true, true, false],
            [true, true, false, true],
            [true, false, true, false],
        ],
        9: [
            [true, true, false, false],
            [true, true, true, true],
            [false, true, false, true],
            [false, true, true, false],
        ],
    ]
}

/// Delivers every processed frame pair's markers. `didDetect` is called on the tracker's
/// serial queue — consumers hop threads (the stage-1 FrameBox pattern).
public protocol StereoMarkerTrackerDelegate: AnyObject {
    func stereoMarkerTracker(_ tracker: StereoMarkerTracker, didDetect markers: StereoMarkers)
}

/// Lane-internal detector seam (mirrors `HandDetecting`): Task 4's Vision rectangle
/// pipeline implements this. Takes the upright eye image; implementers own any
/// undistort / color preprocessing (spec pipeline: undistort → VNDetectRectanglesRequest).
public protocol MarkerDetecting {
    func detectMarkers(in image: CGImage) throws -> [MarkerObservation]
}

/// Task-5 default detector: emits no markers. Replaced by Task 4's Vision detector.
public struct NullMarkerDetector: MarkerDetecting {
    public init() {}
    public func detectMarkers(in image: CGImage) throws -> [MarkerObservation] { [] }
}

/// Decimating, latest-wins, non-blocking marker tracker over the stage-1 stereo feed.
///
/// Sendability: `pending`/`needWorker` are guarded by an NSLock, detection runs confined to
/// the tracker's serial queue, and `CGImage` payloads are immutable — the stage-1 FrameBox pattern.
///
/// Worker model: `accept` stores the newest decimation-passing pair in `pending` and signals the
/// worker only when `needWorker` flips false → true (same lock — no lost wakeups). The worker
/// drains `pending` until empty. Under normal cadence every Nth pair processes; under a burst,
/// `pending` holds only the newest (latest-wins) and one processing covers it.
public final class StereoMarkerTracker: @unchecked Sendable {
    private let detector: any MarkerDetecting
    private let interval: Int
    private let lock = NSLock()
    private var acceptedCount = 0
    private var pending: StereoFrame?
    private var needWorker = false
    private let workSignal = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "com.xrealmirror.markertracker", qos: .userInteractive)

    public weak var delegate: StereoMarkerTrackerDelegate?

    /// - Parameter detector: per-eye marker detector (Task 5 default emits nothing; Task 4 supplies the Vision one).
    /// - Parameter processEveryNthPair: process accepted pairs 0, N, 2N, … (2 = 30fps from 60fps).
    public init(detector: any MarkerDetecting = NullMarkerDetector(), processEveryNthPair: Int = 2) {
        precondition(processEveryNthPair > 0, "processEveryNthPair must be positive")
        self.detector = detector
        self.interval = processEveryNthPair
        queue.async { [weak self] in
            // The 5s timeout bounds the loop's lifetime after the tracker is released: when the
            // tracker deallocates while this closure is blocked in wait(), the next timeout
            // re-evaluates `while let self`, finds nil, and the closure exits.
            while let self {
                _ = self.workSignal.wait(timeout: .now() + .seconds(5))
                while let frame = self.takePending() {
                    self.process(frame)
                }
            }
        }
    }

    /// Non-blocking, O(1) — stores the frame and returns. Safe from any queue; the app calls
    /// this from main inside its existing frame hop.
    public func accept(_ frame: StereoFrame) {
        lock.lock()
        let index = acceptedCount
        acceptedCount += 1
        if index % interval == 0 {
            pending = frame   // newest replaces any older unprocessed pair
            if !needWorker {
                needWorker = true
                workSignal.signal()
            }
        }
        lock.unlock()
    }

    /// Takes the newest pending frame; clears `needWorker` when nothing is left.
    /// The signal decision in `accept` and this clear share the lock, so a frame can never
    /// sit unprocessed with no signal pending.
    private func takePending() -> StereoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = pending else {
            needWorker = false
            return nil
        }
        pending = nil
        return frame
    }

    private func process(_ frame: StereoFrame) {
        let markers = StereoMarkers(
            leftEye: EyeMarkers(markers: detectEye(frame.left.image)),
            rightEye: EyeMarkers(markers: detectEye(frame.right.image)),
            sequence: frame.sequence,
            timestampMicros: frame.timestampMicros)
        delegate?.stereoMarkerTracker(self, didDetect: markers)
    }

    private func detectEye(_ image: CGImage) -> [MarkerObservation] {
        (try? detector.detectMarkers(in: image)) ?? []
    }
}
