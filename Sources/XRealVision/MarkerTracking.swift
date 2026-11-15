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

/// Decimating, latest-wins, non-blocking marker tracker over the stage-1 stereo feed.
/// Contract stub: `accept` emits nothing yet — the worker rules mirror `StereoHandTracker`
/// and land in Person 1 Task 5.
public final class StereoMarkerTracker: @unchecked Sendable {
    private let interval: Int

    public weak var delegate: StereoMarkerTrackerDelegate?

    /// - Parameter processEveryNthPair: process accepted pairs 0, N, 2N, … (2 = 30fps from 60fps).
    public init(processEveryNthPair: Int = 2) {
        self.interval = processEveryNthPair
    }

    /// Non-blocking, O(1) — stub: stores nothing and delivers nothing until Task 5 wires
    /// the worker and the per-eye marker detector.
    public func accept(_ frame: StereoFrame) {}
}
