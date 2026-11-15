import XCTest
import simd
import XRealVision
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 6: fingertip (3-D, camera frame) → (string, fret, height above the fretboard).
final class FingerOnFretboardTests: XCTestCase {
    let board = Fretboard(spec: .yamahaF600)
    /// Guitar somewhere in front of the glasses, tilted (so the test exercises the frame change, not identity).
    let pose: GuitarPose = {
        let r = simd_double3x3(simd_quatd(angle: 0.9, axis: simd_normalize(SIMD3(0.3, 1, 0.2))))
        return GuitarPose(rotation: r, translation: SIMD3(-0.1, 0.2, 0.4), markersUsed: [7, 8, 9], residualRMS: 0, state: .tracking)
    }()

    /// A hand whose five fingertips are at the given guitar-frame points (other joints near the wrist).
    private func hand(tips: [SIMD3<Double>], side: Hand3D.Side = .left) -> Hand3D {
        var joints = [SIMD3<Double>](repeating: pose.toCamera(SIMD3(0.1, -0.1, 0.05)), count: 21)
        for (finger, g) in zip(FingerOnFretboard.Finger.allCases, tips) { joints[finger.tipJoint] = pose.toCamera(g) }
        return Hand3D(joints: joints, meanRayGap: 0.005, side: side, orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Guitar-frame point over string `s` (0 = low E) in fret slot `k` (between fret k−1 and k), `h` above the board.
    private func spot(string s: Int, fret k: Int, height h: Double) -> SIMD3<Double> {
        let x = (board.fretX(k - 1) + board.fretX(k)) / 2 + 0.004 * Double(k % 2)   // somewhere inside the slot
        return SIMD3(x, board.strings[s].point(atX: x).y, h)
    }

    func testGChordShapeIsReadCorrectly() throws {
        // G major (open): middle on low E fret 3, index on A fret 2, ring on high e fret 3; thumb behind the neck,
        // little finger hovering high.
        let tips = [SIMD3(0.10, -0.035, -0.03),                // thumb: behind the neck (below the board)
                    spot(string: 1, fret: 2, height: 0.008),  // index  → A, 2
                    spot(string: 0, fret: 3, height: 0.007),  // middle → E, 3
                    spot(string: 5, fret: 3, height: 0.009),  // ring   → e, 3
                    spot(string: 3, fret: 4, height: 0.045)]  // little hovering 4.5 cm up
        let p = FingerOnFretboard.place(hand: hand(tips: tips), pose: pose, board: board)
        let byFinger = Dictionary(uniqueKeysWithValues: p.map { ($0.finger, $0) })
        XCTAssertEqual(byFinger[.index]?.stringName, "A"); XCTAssertEqual(byFinger[.index]?.fret, 2)
        XCTAssertEqual(byFinger[.middle]?.stringName, "E"); XCTAssertEqual(byFinger[.middle]?.fret, 3)
        XCTAssertEqual(byFinger[.ring]?.stringName, "e"); XCTAssertEqual(byFinger[.ring]?.fret, 3)
        for f in [FingerOnFretboard.Finger.index, .middle, .ring] {
            XCTAssertEqual(byFinger[f]?.pressing, true, "\(f)")
            XCTAssertEqual(byFinger[f]?.onNeck, true)
        }
        XCTAssertEqual(byFinger[.little]?.pressing, false)
        XCTAssertEqual(byFinger[.little]?.height ?? 0, 0.045, accuracy: 1e-9)
        XCTAssertEqual(byFinger[.thumb]?.onNeck, false, "behind the neck is not on the fretboard")
    }

    func testFretSlotBoundaries() {
        for k in [1, 5, 12, 19] {
            let inside = FingerOnFretboard.fretSlot(x: board.fretX(k) - 0.0005, board: board)
            let past = FingerOnFretboard.fretSlot(x: board.fretX(k) + 0.0005, board: board)
            XCTAssertEqual(inside, k)
            XCTAssertEqual(past, k + 1)
        }
        XCTAssertNil(FingerOnFretboard.fretSlot(x: -0.002, board: board), "behind the nut")
        XCTAssertNil(FingerOnFretboard.fretSlot(x: board.fretX(20) + 0.02, board: board), "past the last fret")
    }

    func testOffTheSideOfTheNeckHasNoString() {
        let x = board.fretX(5)
        let outside = SIMD3(x, board.halfWidth(atX: x) + 0.02, 0.005)
        let p = FingerOnFretboard.place(hand: hand(tips: [outside, outside, outside, outside, outside]), pose: pose, board: board)
        XCTAssertTrue(p.allSatisfy { $0.string == nil && !$0.onNeck })
    }

    func testNearestStringPicksTheClosestOne() {
        let x = board.fretX(3)
        let a = board.strings[1].point(atX: x).y, d = board.strings[2].point(atX: x).y
        let nearA = SIMD3(x - 0.01, a + 0.3 * (d - a), 0.006)   // 30 % of the way from A to D → A
        let nearD = SIMD3(x - 0.01, a + 0.7 * (d - a), 0.006)   // 70 % → D
        let p = FingerOnFretboard.place(hand: hand(tips: [nearA, nearD, nearA, nearD, nearA]), pose: pose, board: board)
        XCTAssertEqual(p[0].stringName, "A")
        XCTAssertEqual(p[1].stringName, "D")
    }

    func testDescriptionReadsLikeACoachWould() {
        let p = FingerOnFretboard.place(hand: hand(tips: [spot(string: 1, fret: 2, height: 0.008)] + [SIMD3](repeating: SIMD3(0.1, 0.2, 0.2), count: 4)),
                                        pose: pose, board: board)
        XCTAssertEqual(p[0].summary, "thumb: A string, fret 2, pressing")
    }
}
