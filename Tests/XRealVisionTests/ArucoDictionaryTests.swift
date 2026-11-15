import XCTest
@testable import XRealVision

final class ArucoDictionaryTests: XCTestCase {

    /// Pins the three 4×4 ArUco bit patterns against the printed PDFs
    /// (spec "Facts" table: rows top→bottom as printed upright, `true` = white).
    /// If a pattern disagrees with the printout, STOP and report — never edit
    /// the dictionary to make this pass.
    func testArucoPatternsMatchThePrintedPDFs() {
        let expected: [Int: [[Bool]]] = [
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

        XCTAssertEqual(ArucoDictionary.markers.count, 3, "dictionary must hold exactly IDs 7, 8, 9")
        for (id, pattern) in expected {
            guard let actual = ArucoDictionary.markers[id] else {
                XCTFail("ArucoDictionary.markers is missing ID \(id)")
                continue
            }
            XCTAssertEqual(actual, pattern, "ID \(id) pattern must match the printed PDF, rows top→bottom, true = white")
        }
    }
}
