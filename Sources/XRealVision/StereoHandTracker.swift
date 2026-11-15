import CoreGraphics
import Foundation

/// Delivers every processed frame pair's hands. `didTrack` is called on the tracker's
/// serial queue — consumers hop threads (the app hops to main, stage-1 FrameBox pattern).
/// Always non-nil `StereoHands`; empty `hands` arrays mean "no hands in that eye".
public protocol StereoHandTrackerDelegate: AnyObject {
    func stereoHandTracker(_ tracker: StereoHandTracker, didTrack hands: StereoHands)
}

/// Decimating, latest-wins, non-blocking hand tracker over the stage-1 stereo feed.
///
/// Sendability: `pending`/`needWorker` are guarded by an NSLock, detection runs confined to
/// the tracker's serial queue, and `CGImage` payloads are immutable — the stage-1 FrameBox pattern.
///
/// Worker model: `accept` stores the newest decimation-passing pair in `pending` and signals the
/// worker only when `needWorker` flips false → true (same lock — no lost wakeups). The worker
/// drains `pending` until empty. Under normal cadence every Nth pair processes; under a burst,
/// `pending` holds only the newest (latest-wins) and one processing covers it.
public final class StereoHandTracker: @unchecked Sendable {
    private let detector: any HandDetecting
    private let interval: Int
    private let lock = NSLock()
    private var acceptedCount = 0
    private var pending: StereoFrame?
    private var needWorker = false
    private let workSignal = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "com.xrealmirror.handtracker", qos: .userInteractive)

    public weak var delegate: StereoHandTrackerDelegate?

    /// - Parameter processEveryNthPair: process accepted pairs 0, N, 2N, … (2 = 30fps from 60fps).
    public init(detector: any HandDetecting = VisionHandDetector(), processEveryNthPair: Int = 2) {
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
        let hands = StereoHands(
            leftEye: EyeHands(hands: detectEye(frame.left.image)),
            rightEye: EyeHands(hands: detectEye(frame.right.image)),
            sequence: frame.sequence,
            timestampMicros: frame.timestampMicros)
        delegate?.stereoHandTracker(self, didTrack: hands)
    }

    private func detectEye(_ image: CGImage) -> [TrackedHand] {
        guard let rgb = GrayToRGB.convert(image: image) else { return [] }
        return (try? detector.detectHands(in: rgb)) ?? []
    }
}
