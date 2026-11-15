import Foundation
import XCTest
import simd
@testable import XRealMirrorApp

/// Fretboard stage, Person 2 Task 2. Guitar frame (spec): origin = nut centre on the fretboard surface, +x toward
/// the bridge, +y toward the treble (high-E) side, +z out of the fretboard. Metres.
final class FretboardTests: XCTestCase {
    let board = Fretboard(spec: .yamahaF600)

    func testTwelfthFretIsHalfTheScale() {
        XCTAssertEqual(board.fretX(12), 0.317, accuracy: 1e-9)
        XCTAssertEqual(board.fretX(0), 0, accuracy: 1e-12)          // the nut
        XCTAssertEqual(board.fretX(24), 0.634 * 0.75, accuracy: 1e-9)
    }

    func testFretSpacingShrinksTowardTheBody() {
        let gaps = (1...20).map { board.fretX($0) - board.fretX($0 - 1) }
        for i in 1..<gaps.count { XCTAssertLessThan(gaps[i], gaps[i - 1]) }
        XCTAssertEqual(gaps[0], 0.634 * (1 - pow(2, -1.0 / 12)), accuracy: 1e-9)   // ≈ 35.6 mm
    }

    func testFretboardTapersFromNutToTwelfth() {
        XCTAssertEqual(board.halfWidth(atX: 0) * 2, 0.043, accuracy: 1e-9)
        XCTAssertEqual(board.halfWidth(atX: 0.317) * 2, Fretboard.Spec.yamahaF600.widthAt12th, accuracy: 1e-9)
        XCTAssertGreaterThan(board.halfWidth(atX: board.fretX(20)), board.halfWidth(atX: 0.317))
    }

    func testFretLinesSpanTheBoardAcrossY() {
        for k in [1, 5, 12, 20] {
            let line = board.fretLine(k)
            XCTAssertEqual(line.0.x, board.fretX(k), accuracy: 1e-12)
            XCTAssertEqual(line.1.x, board.fretX(k), accuracy: 1e-12)
            XCTAssertEqual(line.0.y, -board.halfWidth(atX: board.fretX(k)), accuracy: 1e-12)   // bass edge first
            XCTAssertEqual(line.1.y, board.halfWidth(atX: board.fretX(k)), accuracy: 1e-12)
        }
    }

    func testStringsFanOutTowardTheBridgeAndHighEIsOnPlusY() {
        XCTAssertEqual(board.strings.count, 6)
        let low = board.strings[0], high = board.strings[5]   // index 0 = low E (6th string), 5 = high E (1st)
        XCTAssertLessThan(low.nut.y, 0)
        XCTAssertGreaterThan(high.nut.y, 0)
        XCTAssertEqual(high.nut.y - low.nut.y, Fretboard.Spec.yamahaF600.stringSpreadAtNut, accuracy: 1e-9)
        XCTAssertEqual(high.saddle.y - low.saddle.y, Fretboard.Spec.yamahaF600.stringSpreadAtSaddle, accuracy: 1e-9)
        XCTAssertEqual(low.saddle.x, 0.634, accuracy: 1e-9)
        for i in 1..<6 { XCTAssertGreaterThan(board.strings[i].nut.y, board.strings[i - 1].nut.y) }
        XCTAssertEqual(board.strings.map(\.name), ["E", "A", "D", "G", "B", "e"])
    }

    func testStringsSitAboveTheBoardAndRiseTowardTheBody() {
        let s = board.strings[0]
        XCTAssertGreaterThan(s.point(atX: 0).z, 0)
        XCTAssertGreaterThan(s.point(atX: 0.317).z, s.point(atX: 0).z)
        // Interpolates linearly in y between nut and saddle spacing.
        let mid = s.point(atX: 0.317)
        XCTAssertEqual(mid.y, (s.nut.y + s.saddle.y) / 2, accuracy: 1e-9)
    }

    func testSpecJSONRoundTripsAndTheShippedFileMatches() throws {
        let data = try JSONEncoder().encode(Fretboard.Spec.yamahaF600)
        XCTAssertEqual(try JSONDecoder().decode(Fretboard.Spec.self, from: data), .yamahaF600)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/guitar/f600.json")
        XCTAssertEqual(try JSONDecoder().decode(Fretboard.Spec.self, from: Data(contentsOf: file)), .yamahaF600,
                       "tools/guitar/f600.json and Fretboard.Spec.yamahaF600 must agree — update both together")
    }
}
