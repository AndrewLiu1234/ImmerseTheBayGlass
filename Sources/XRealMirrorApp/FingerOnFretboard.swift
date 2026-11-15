import AppKit
import Foundation
import simd
import XRealVision

/// Where a fingertip is on the fretboard: nearest string, fret slot, height above the board.
struct FingerPlacement: Sendable, Equatable {
    var finger: FingerOnFretboard.Finger
    var side: Hand3D.Side
    var string: Int?            // 0 = low E (6th) … 5 = high E (1st); nil if not over the neck
    var stringName: String?
    var fret: Int?              // fret slot: 1 = between the nut and fret 1; nil behind the nut / past the last fret
    var height: Double          // above the fretboard surface (guitar +z), metres; negative = below/behind
    var onNeck: Bool            // over the fretboard (any string, any fret slot) and not behind it
    var pressing: Bool          // onNeck and low enough to be holding a string down
    var tip: SIMD3<Double>      // the fingertip, LEFT camera frame (for drawing its state in each eye / in 3-D)

    /// e.g. "index: A string, fret 2, pressing".
    var summary: String {
        guard onNeck, let s = stringName, let f = fret else { return "\(finger.name): off the fretboard" }
        return "\(finger.name): \(s) string, fret \(f), \(pressing ? "pressing" : "hovering")"
    }
}

enum FingerOnFretboard {
    enum Finger: Int, CaseIterable, Sendable {
        case thumb, index, middle, ring, little
        var tipJoint: Int {
            [HandJoint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip][rawValue].rawValue
        }
        var name: String { ["thumb", "index", "middle", "ring", "little"][rawValue] }
    }

    /// A fingertip landmark sits on the finger pad's centre, not the contact point, and the 3-D hands are good to
    /// ≈ 1 cm (stage 3: rays meet within ≈ 7 mm). PLACEHOLDER until tuned on Person 1's `play` dataset (plan Task 6).
    static let defaultPressHeight = 0.015
    /// How far past the fretboard edge a fingertip still counts as over the outer string.
    static let edgeMargin = 0.004

    static func place(hand: Hand3D, pose: GuitarPose, board: Fretboard,
                      pressHeight: Double = defaultPressHeight) -> [FingerPlacement] {
        Finger.allCases.map { finger in
            let g = pose.toGuitar(hand.joints[finger.tipJoint])
            let slot = fretSlot(x: g.x, board: board)
            let overBoard = slot != nil && abs(g.y) <= board.halfWidth(atX: max(0, g.x)) + edgeMargin && g.z > -0.005
            let string = overBoard ? nearestString(x: g.x, y: g.y, board: board) : nil
            let onNeck = overBoard && string != nil
            return FingerPlacement(finger: finger, side: hand.side, string: string,
                                   stringName: string.map { board.strings[$0].name }, fret: onNeck ? slot : nil,
                                   height: g.z, onNeck: onNeck, pressing: onNeck && g.z < pressHeight,
                                   tip: hand.joints[finger.tipJoint])
        }
    }

    /// Fret slot containing x: k means between fret k−1 (k = 1: the nut) and fret k.
    static func fretSlot(x: Double, board: Fretboard) -> Int? {
        guard x >= 0 else { return nil }
        return (1...board.spec.fretCount).first { x <= board.fretX($0) }
    }

    static func nearestString(x: Double, y: Double, board: Fretboard) -> Int? {
        board.strings.indices.min { abs(board.strings[$0].point(atX: x).y - y) < abs(board.strings[$1].point(atX: x).y - y) }
    }
}

/// Fingertip state marks for drawing: only fingertips over the fretboard, projected into one eye.
enum FingertipMarks {
    enum State: Sendable, Equatable { case pressing, hovering }
    struct Mark: Sendable, Equatable {
        var point: SIMD2<Float>      // contract-normalized (origin top-left, 0…1 over the 480×640 image)
        var state: State
    }

    static func marks(_ placements: [FingerPlacement], eye: FretboardProjection.Eye,
                      calibration: StereoCalibration) -> [Mark] {
        placements.filter(\.onNeck).compactMap { p in
            let px: SIMD2<Double>?
            switch eye {
            case .left: px = calibration.left.project(p.tip)
            case .right: px = calibration.right.project(calibration.leftToRight(p.tip))
            }
            guard let px else { return nil }
            let n = (px + 0.5) / FretboardProjection.imageSize
            return Mark(point: SIMD2(Float(n.x), Float(n.y)), state: p.pressing ? .pressing : .hovering)
        }
    }

    static func color(for state: State) -> NSColor { state == .pressing ? .systemGreen : .systemYellow }
}
