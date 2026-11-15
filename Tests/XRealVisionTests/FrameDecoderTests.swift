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
    // Inverse rotations re-derived from the spec, for building expected scans in tests.
    private func scanForLeft(upright: [UInt8]) -> [UInt8] {
        // Left is CCW: scan[c*640+r] = upright[(639-r)*480+c]
        // c = upright column (0..<480), r = upright row (0..<640)
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for c in 0..<FrameLayout.sensorHeight {
            for r in 0..<FrameLayout.sensorWidth {
                scan[c * FrameLayout.sensorWidth + r] =
                    upright[(FrameLayout.uprightHeight - 1 - r) * FrameLayout.uprightWidth + c]
            }
        }
        return scan
    }
    private func scanForRight(upright: [UInt8]) -> [UInt8] {
        // Right is CW: scan[c*640+r] = upright[r*480 + (479-c)]
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for c in 0..<FrameLayout.sensorHeight {
            for r in 0..<FrameLayout.sensorWidth {
                scan[c * FrameLayout.sensorWidth + r] =
                    upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)]
            }
        }
        return scan
    }

    func testEncodeProducesFrameBytesWithPadding() {
        let upright = [UInt8](repeating: 0x7F, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.left,
                                             sequence: 0x1234, align: 9, timestampMicros: 1)
        XCTAssertEqual(frame.count, FrameLayout.frameBytes)
        XCTAssertTrue(frame[FrameLayout.paddingOffset..<FrameLayout.frameBytes].allSatisfy { $0 == 0x5C })
    }

    func testMetadataOffsets() {
        let upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let seq: UInt16 = 0xAB12
        let ts: UInt64 = 0x0102030405060708
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.right,
                                             sequence: seq, align: 0, timestampMicros: ts)
        XCTAssertEqual(UInt16(frame[FrameLayout.metadataOffset + 0x12])
                       | (UInt16(frame[FrameLayout.metadataOffset + 0x13]) << 8), seq)
        XCTAssertEqual(frame[FrameLayout.metadataOffset + 0x3A], CameraID.right)  // NOT +0x3B
        var tsBytes: UInt64 = 0
        for i in 0..<8 { tsBytes |= UInt64(frame[FrameLayout.metadataOffset + 0x3E + i]) << (8 * i) }
        XCTAssertEqual(tsBytes, ts)
    }

    private func uprightForLeft(scan: [UInt8]) -> [UInt8] {
        // Forward of the left inverse (the spec's own formula direction):
        // upright[(639-r)*480+c] = scan[c*640+r]
        var upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        for c in 0..<FrameLayout.sensorHeight {
            for r in 0..<FrameLayout.sensorWidth {
                upright[(FrameLayout.uprightHeight - 1 - r) * FrameLayout.uprightWidth + c] =
                    scan[c * FrameLayout.sensorWidth + r]
            }
        }
        return upright
    }
    private func uprightForRight(scan: [UInt8]) -> [UInt8] {
        // Forward of the right inverse: upright[r*480 + (479-c)] = scan[c*640+r]
        var upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        for c in 0..<FrameLayout.sensorHeight {
            for r in 0..<FrameLayout.sensorWidth {
                upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)] =
                    scan[c * FrameLayout.sensorWidth + r]
            }
        }
        return upright
    }

    func testEncodeDecodeRoundTripBothEyes() {
        // Fixture scan: block 0 is the black-vignette sync block (unique smallest 128-byte sum,
        // as the hardware produces), and every other block carries a distinct byte value so any
        // mis-permutation or wrong rotation changes the bytes, not just their order.
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for t in 1..<FrameLayout.blocks {
            let v = UInt8(t)   // 1...127, all nonzero and distinct per block
            for i in (t * FrameLayout.blockBytes)..<((t + 1) * FrameLayout.blockBytes) { scan[i] = v }
        }
        for cameraID in [CameraID.left, CameraID.right] {
            let upright = cameraID == CameraID.left ? uprightForLeft(scan: scan)
                                                    : uprightForRight(scan: scan)
            for align in [0, 1, 64, 127] {
                let frame = XRealFrameDecoder.encode(upright: upright, cameraID: cameraID,
                                                     sequence: 42, align: align, timestampMicros: 7)
                guard let decoded = XRealFrameDecoder.decode(frame) else {
                    XCTFail("decode returned nil (cameraID \(cameraID), align \(align))"); continue
                }
                XCTAssertEqual(decoded.cameraID, cameraID)
                XCTAssertEqual(decoded.sequence, 42)
                XCTAssertEqual(decoded.align, align)
                XCTAssertEqual(decoded.timestampMicros, 7)
                XCTAssertEqual(decoded.scan, scan, "cameraID \(cameraID), align \(align)")
            }
        }
    }

    func testDecodeRejectsWrongSize() {
        XCTAssertNil(XRealFrameDecoder.decode([UInt8](repeating: 0, count: 100)))
        XCTAssertNil(XRealFrameDecoder.decode([UInt8](repeating: 0, count: FrameLayout.frameBytes - 1)))
    }

    func testDecodeAllZeroFrameIsValid() {
        // Warmup frames are all zeros and are legitimate content — the decoder must not treat
        // them as errors; skip logic lives in StereoCamera.
        let upright = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let frame = XRealFrameDecoder.encode(upright: upright, cameraID: CameraID.left,
                                             sequence: 0, align: 0, timestampMicros: 0)
        let decoded = XRealFrameDecoder.decode(frame)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.scan.allSatisfy { $0 == 0 })
    }

    private func cgImageBytes(_ img: CGImage) -> [UInt8]? {
        guard let data = img.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }
    private func mirrorHorizontal(_ upright: [UInt8]) -> [UInt8] {
        var out = upright
        for r in 0..<FrameLayout.uprightHeight {
            for c in 0..<FrameLayout.uprightWidth {
                out[r * FrameLayout.uprightWidth + c] = upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)]
            }
        }
        return out
    }
    private func markerUpright() -> [UInt8] {
        var u = [UInt8](repeating: 0, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        u[12 * FrameLayout.uprightWidth + 34] = 0xFF   // single marker pixel at (row 12, col 34)
        return u
    }

    func testRotateLeftOrientsMarkerPixel() {
        let u = markerUpright()
        XCTAssertEqual(XRealFrameDecoder.rotateLeft(scanForLeft(upright: u)), u)
    }

    func testRotateRightOrientsMarkerPixel() {
        let u = markerUpright()
        XCTAssertEqual(XRealFrameDecoder.rotateRight(scanForRight(upright: u)), u)
    }

    func testLeftAndRightRotationsAreNotMirrors() {
        // The guide's trap: a plain transpose yields a mirrored image. A mirror of an
        // asymmetric pattern must not equal the true rotation.
        let u = markerUpright()
        let scan = scanForLeft(upright: u)
        XCTAssertEqual(XRealFrameDecoder.rotateLeft(scan), u)
        XCTAssertNotEqual(XRealFrameDecoder.rotateLeft(scan), mirrorHorizontal(u))
    }

    func testMakeEyeImageChoosesRotationByCameraID() {
        let u = markerUpright()
        let left = XRealFrameDecoder.makeEyeImage(scan: scanForLeft(upright: u), cameraID: CameraID.left)
        let right = XRealFrameDecoder.makeEyeImage(scan: scanForRight(upright: u), cameraID: CameraID.right)
        XCTAssertEqual(cgImageBytes(left!), u)
        XCTAssertEqual(cgImageBytes(right!), u)
    }

    func testMakeCGImageGeometry() {
        let u = [UInt8](repeating: 0x80, count: FrameLayout.uprightWidth * FrameLayout.uprightHeight)
        let img = XRealFrameDecoder.makeCGImage(upright: u)
        XCTAssertEqual(img?.width, FrameLayout.uprightWidth)
        XCTAssertEqual(img?.height, FrameLayout.uprightHeight)
        XCTAssertEqual(img?.bitsPerPixel, 8)
    }
}
