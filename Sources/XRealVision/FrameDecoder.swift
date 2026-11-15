import Accelerate
import CoreGraphics

public enum FrameLayout {
    public static let sensorWidth = 640
    public static let sensorHeight = 480
    public static let uprightWidth = 480
    public static let uprightHeight = 640
    public static let blocks = 128
    public static let blockBytes = 2_400
    public static let imageBytes = 307_200
    public static let metadataOffset = 307_200
    public static let paddingOffset = 307_840
    public static let frameBytes = 308_480

public static let reorderMap: [Int] = [
    119, 54, 21, 0, 108, 22, 51, 63, 93, 99, 67, 7, 32, 112, 52, 43,
    14, 35, 75, 116, 64, 71, 44, 89, 18, 88, 26, 61, 70, 56, 90, 79,
    87, 120, 81, 101, 121, 17, 72, 31, 53, 124, 127, 113, 111, 36, 48,
    19, 37, 83, 126, 74, 109, 5, 84, 41, 76, 30, 110, 29, 12, 115, 28,
    102, 105, 62, 103, 20, 3, 68, 49, 77, 117, 125, 106, 60, 69, 98, 9,
    16, 78, 47, 40, 2, 118, 34, 13, 50, 46, 80, 85, 66, 42, 123, 122,
    96, 11, 25, 97, 39, 6, 86, 1, 8, 82, 92, 59, 104, 24, 15, 73, 65,
    38, 58, 10, 23, 33, 55, 57, 107, 100, 94, 27, 95, 45, 91, 4, 114,
]
}

public enum XRealFrameDecoder {
    /// Copies logical block `t` from raw block `reorderMap[(align + t) % blocks]`.
    /// Returns an empty array if the payload is not exactly one image payload.
    public static func unpermute(payload: [UInt8], align: Int) -> [UInt8] {
        guard payload.count == FrameLayout.imageBytes else { return [] }
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        for t in 0..<FrameLayout.blocks {
            let rawBlock = FrameLayout.reorderMap[(align + t) % FrameLayout.blocks]
            let dst = t * FrameLayout.blockBytes
            let src = rawBlock * FrameLayout.blockBytes
            scan.replaceSubrange(dst..<(dst + FrameLayout.blockBytes),
                                 with: payload[src..<(src + FrameLayout.blockBytes)])
        }
        return scan
    }

    /// The sync block (logical block 0, a black vignette) has the smallest sum of its
    /// first 128 bytes. Returns nil unless the payload is exactly one image payload.
    public static func recoverAlign(payload: [UInt8]) -> Int? {
        guard payload.count == FrameLayout.imageBytes else { return nil }
        var inverseMap = [Int](repeating: 0, count: FrameLayout.blocks)
        for i in 0..<FrameLayout.blocks { inverseMap[FrameLayout.reorderMap[i]] = i }
        var bestSum = Int.max
        var sync = 0
        for b in 0..<FrameLayout.blocks {
            let start = b * FrameLayout.blockBytes
            var sum = 0
            for i in start..<(start + 128) { sum += Int(payload[i]) }
            if sum < bestSum {  // strictly less: first occurrence wins ties
                bestSum = sum
                sync = b
            }
        }
        return inverseMap[sync]
    }

    /// Decodes a full 308,480-byte frame: recovers align, unpermutes the payload,
    /// and parses the metadata row (sequence LE at +0x12, camera ID at +0x3A,
    /// timestamp LE at +0x3E). Returns nil unless the frame has the exact frame size.
    public static func decode(_ frame: [UInt8]) -> DecodedFrame? {
        guard frame.count == FrameLayout.frameBytes else { return nil }
        let payload = Array(frame[0..<FrameLayout.imageBytes])
        guard let align = recoverAlign(payload: payload) else { return nil }
        let scan = unpermute(payload: payload, align: align)
        let m = FrameLayout.metadataOffset
        let sequence = UInt16(frame[m + 0x12]) | (UInt16(frame[m + 0x13]) << 8)
        let cameraID = frame[m + 0x3A]
        var timestampMicros: UInt64 = 0
        for i in 0..<8 { timestampMicros |= UInt64(frame[m + 0x3E + i]) << (8 * i) }
        return DecodedFrame(scan: scan, align: align, sequence: sequence,
                            cameraID: cameraID, timestampMicros: timestampMicros)
    }

    /// Inverse of the decode pipeline; the test oracle. Builds the column-major scan by the
    /// inverse rotation for the camera, permutes it into raw blocks, writes the metadata row,
    /// and fills the trailing region with 0x5C padding. Returns an empty array for a wrong
    /// upright size or an unknown camera ID.
    public static func encode(upright: [UInt8], cameraID: UInt8, sequence: UInt16,
                              align: Int, timestampMicros: UInt64) -> [UInt8] {
        guard upright.count == FrameLayout.uprightWidth * FrameLayout.uprightHeight else { return [] }
        guard cameraID == CameraID.left || cameraID == CameraID.right else { return [] }
        var scan = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        if cameraID == CameraID.left {
            // Left is CCW: upright[639-r][c] = scan[c*640+r]
            for c in 0..<FrameLayout.sensorHeight {          // c = source row
                for r in 0..<FrameLayout.sensorWidth {       // r = source column
                    scan[c * FrameLayout.sensorWidth + r] =
                        upright[(FrameLayout.uprightHeight - 1 - r) * FrameLayout.uprightWidth + c]
                }
            }
        } else {
            // Right is CW: upright[r][479-c] = scan[c*640+r]
            for c in 0..<FrameLayout.sensorHeight {
                for r in 0..<FrameLayout.sensorWidth {
                    scan[c * FrameLayout.sensorWidth + r] =
                        upright[r * FrameLayout.uprightWidth + (FrameLayout.uprightWidth - 1 - c)]
                }
            }
        }
        var frame = [UInt8](repeating: 0, count: FrameLayout.frameBytes)
        for t in 0..<FrameLayout.blocks {
            let src = t * FrameLayout.blockBytes
            let dst = FrameLayout.reorderMap[(align + t) % FrameLayout.blocks] * FrameLayout.blockBytes
            frame.replaceSubrange(dst..<(dst + FrameLayout.blockBytes),
                                  with: scan[src..<(src + FrameLayout.blockBytes)])
        }
        let m = FrameLayout.metadataOffset
        frame[m + 0x12] = UInt8(truncatingIfNeeded: sequence)
        frame[m + 0x13] = UInt8(truncatingIfNeeded: sequence >> 8)
        frame[m + 0x3A] = cameraID
        for i in 0..<8 { frame[m + 0x3E + i] = UInt8(truncatingIfNeeded: timestampMicros >> (8 * i)) }
        for i in FrameLayout.paddingOffset..<FrameLayout.frameBytes { frame[i] = 0x5C }
        return frame
    }

    /// Rotates the 640x480 column-major scan 90° counter-clockwise into the upright 480x640 layout
    /// (left camera, 0x20). Uses vImageRotate90_Planar8 — a manual transpose would mirror the image.
    public static func rotateLeft(_ scan: [UInt8]) -> [UInt8] {
        rotate(scan, constant: UInt8(kRotate90DegreesCounterClockwise))
    }

    /// 90° clockwise (right camera, 0x21).
    public static func rotateRight(_ scan: [UInt8]) -> [UInt8] {
        rotate(scan, constant: UInt8(kRotate90DegreesClockwise))
    }

    private static func rotate(_ scan: [UInt8], constant: UInt8) -> [UInt8] {
        guard scan.count == FrameLayout.imageBytes else { return [] }
        var out = [UInt8](repeating: 0, count: FrameLayout.imageBytes)
        scan.withUnsafeBufferPointer { srcBytes in
            out.withUnsafeMutableBufferPointer { dstBytes in
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBytes.baseAddress!),
                    height: vImagePixelCount(FrameLayout.sensorHeight),
                    width: vImagePixelCount(FrameLayout.sensorWidth),
                    rowBytes: FrameLayout.sensorWidth)
                var dst = vImage_Buffer(
                    data: dstBytes.baseAddress!,
                    height: vImagePixelCount(FrameLayout.sensorWidth),
                    width: vImagePixelCount(FrameLayout.sensorHeight),
                    rowBytes: FrameLayout.sensorHeight)
                _ = vImageRotate90_Planar8(&src, &dst, constant, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// Wraps a 480x640 greyscale upright buffer in a CGImage.
    public static func makeCGImage(upright: [UInt8]) -> CGImage? {
        guard upright.count == FrameLayout.uprightWidth * FrameLayout.uprightHeight else { return nil }
        guard let provider = CGDataProvider(data: Data(upright) as CFData) else { return nil }
        return CGImage(width: FrameLayout.uprightWidth,
                       height: FrameLayout.uprightHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: FrameLayout.uprightWidth,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Decodes a scan into an upright CGImage, choosing the rotation by camera ID.
    public static func makeEyeImage(scan: [UInt8], cameraID: UInt8) -> CGImage? {
        switch cameraID {
        case CameraID.left:  return makeCGImage(upright: rotateLeft(scan))
        case CameraID.right: return makeCGImage(upright: rotateRight(scan))
        default:             return nil
        }
    }
}

public struct DecodedFrame {
    public let scan: [UInt8]           // 307,200 bytes, block-unpermuted, still column-major
    public let align: Int              // 0..<128, recovered
    public let sequence: UInt16        // uint16 LE at metadataOffset + 0x12
    public let cameraID: UInt8         // uint8 at metadataOffset + 0x3A
    public let timestampMicros: UInt64 // uint64 LE at metadataOffset + 0x3E
}
