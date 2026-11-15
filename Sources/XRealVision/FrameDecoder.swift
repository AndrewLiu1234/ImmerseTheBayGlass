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
}
