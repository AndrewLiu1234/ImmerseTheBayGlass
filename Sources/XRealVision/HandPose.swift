import simd

/// One hand's handedness, as reported by the detector.
public enum HandChirality: Sendable { case left, right, unknown }

/// One tracked hand: 21 landmarks in canonical `HandJoint` order, normalized 0...1
/// with origin at the TOP-LEFT of the upright image (the contract flips Vision's
/// bottom-left origin; see `HandObservationMapper`).
public struct TrackedHand: Sendable {
    public var landmarks: [SIMD2<Float>]   // 21, canonical order
    public var confidences: [Float]        // 21, same order
    public var chirality: HandChirality

    public init(landmarks: [SIMD2<Float>], confidences: [Float], chirality: HandChirality) {
        self.landmarks = landmarks
        self.confidences = confidences
        self.chirality = chirality
    }
}

/// Hands seen by one eye in one frame. Empty means "no hands" — normal, not an error.
public struct EyeHands: Sendable {
    public var hands: [TrackedHand]        // 0...2, unordered

    public init(hands: [TrackedHand] = []) {
        self.hands = hands
    }
}

/// Both eyes' hands for one processed frame pair, plus the source frame's identity.
public struct StereoHands: Sendable {
    public var leftEye: EyeHands
    public var rightEye: EyeHands
    public var sequence: UInt16            // the source StereoFrame's sequence
    public var timestampMicros: UInt64
}

/// The canonical 21-joint order. `rawValue` is the index into every 21-element
/// landmarks/confidences array in this contract. NEVER reorder — Lane 2 indexes by it.
public enum HandJoint: Int, CaseIterable, Sendable {
    case wrist = 0, thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public struct HandConnection: Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// The canonical hand-skeleton connections (21 edges, MediaPipe HAND_CONNECTIONS layout).
public enum HandSkeleton {
    public static let connections: [HandConnection] = [
        HandConnection(from: 0, to: 1),  HandConnection(from: 1, to: 2),
        HandConnection(from: 2, to: 3),  HandConnection(from: 3, to: 4),
        HandConnection(from: 0, to: 5),  HandConnection(from: 5, to: 6),
        HandConnection(from: 6, to: 7),  HandConnection(from: 7, to: 8),
        HandConnection(from: 5, to: 9),  HandConnection(from: 9, to: 10),
        HandConnection(from: 10, to: 11), HandConnection(from: 11, to: 12),
        HandConnection(from: 9, to: 13), HandConnection(from: 13, to: 14),
        HandConnection(from: 14, to: 15), HandConnection(from: 15, to: 16),
        HandConnection(from: 13, to: 17), HandConnection(from: 17, to: 18),
        HandConnection(from: 18, to: 19), HandConnection(from: 19, to: 20),
        HandConnection(from: 0, to: 17),
    ]
}
