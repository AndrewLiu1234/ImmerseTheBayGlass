import XCTest
@testable import XRealVision

final class FrameDecoderTests: XCTestCase {
    // Deterministic pseudo-random scan fill so byte POSITIONS differ (a per-block constant would
    // survive any permutation and prove nothing).
    private func pattern(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8((($0 &* 131) &+ 17) & 0xFF) }
    }

    // Hardware permutation math, re-derived from the spec for the test's own use.
    private func permute(scan: [UInt8], align: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for t in 0..<FrameLayout.blocks {
            let src = t * FrameLayout.blockBytes
            let dst = FrameLayout.reorderMap[(align + t) % FrameLayout.blocks] * FrameLayout.blockBytes
            raw.replaceSubrange(dst..<(dst + FrameLayout.blockBytes),
                                with: scan[src..<(src + FrameLayout.blockBytes)])
        }
        return raw
    }

    func testReorderMapIsPermutationOf0To127() {
        XCTAssertEqual(FrameLayout.reorderMap.count, 128)
        XCTAssertEqual(Set(FrameLayout.reorderMap).count, 128)
        XCTAssertEqual(FrameLayout.reorderMap.min(), 0)
        XCTAssertEqual(FrameLayout.reorderMap.max(), 127)
    }

    func testLayoutConstants() {
        XCTAssertEqual(FrameLayout.sensorWidth, 640)
        XCTAssertEqual(FrameLayout.sensorHeight, 480)
        XCTAssertEqual(FrameLayout.uprightWidth, 480)
        XCTAssertEqual(FrameLayout.uprightHeight, 640)
        XCTAssertEqual(FrameLayout.blocks, 128)
        XCTAssertEqual(FrameLayout.blockBytes, 2_400)
        XCTAssertEqual(FrameLayout.imageBytes, 307_200)
        XCTAssertEqual(FrameLayout.metadataOffset, 307_200)
        XCTAssertEqual(FrameLayout.paddingOffset, 307_840)
        XCTAssertEqual(FrameLayout.frameBytes, 308_480)
    }

    func testUnpermuteRestoresLogicalOrder() {
        let scan = pattern(FrameLayout.imageBytes)
        for align in [0, 1, 37, 127] {
            let raw = permute(scan: scan, align: align)
            XCTAssertEqual(XRealFrameDecoder.unpermute(payload: raw, align: align), scan,
                           "align \(align) round-trip")
        }
    }

    func testRecoverAlignFindsSmallestSumBlock() {
        var scan = [UInt8](repeating: 0xFF, count: FrameLayout.imageBytes)
        // Logical block 0 is the sync block (black vignette): all zeros, unique smallest 128-byte sum.
        scan.replaceSubrange(0..<FrameLayout.blockBytes,
                             with: [UInt8](repeating: 0, count: FrameLayout.blockBytes))
        for align in [0, 5, 63, 127] {
            let raw = permute(scan: scan, align: align)
            XCTAssertEqual(XRealFrameDecoder.recoverAlign(payload: raw), align, "align \(align)")
        }
    }

    func testRecoverAlignReturnsNilForWrongSize() {
        XCTAssertNil(XRealFrameDecoder.recoverAlign(payload: [UInt8](repeating: 0, count: 100)))
    }
}
