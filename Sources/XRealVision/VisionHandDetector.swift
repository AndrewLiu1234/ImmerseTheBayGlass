import Accelerate
import CoreGraphics
import simd
import Vision

/// Grayscale → RGB888 conversion. Vision is documented for color input; converting
/// unconditionally is cheap insurance (~0.1ms at 480x640) and keeps the MediaPipe slot
/// honest (MediaPipe requires RGB).
public enum GrayToRGB {
    /// Core, test-pinned path: a byte array (row-major, `width` bytes per row) → RGB888 CGImage.
    public static func convert(upright: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, upright.count == width * height else { return nil }
        var srcData = upright
        return srcData.withUnsafeMutableBytes { srcBytes in
            var src = vImage_Buffer(data: srcBytes.baseAddress,
                                    height: vImagePixelCount(height),
                                    width: vImagePixelCount(width),
                                    rowBytes: width)
            var dstData = [UInt8](repeating: 0, count: width * 3 * height)
            return dstData.withUnsafeMutableBytes { dstBytes -> CGImage? in
                var dst = vImage_Buffer(data: dstBytes.baseAddress,
                                        height: vImagePixelCount(height),
                                        width: vImagePixelCount(width),
                                        rowBytes: width * 3)
                let err = vImageConvert_Planar8toRGB888(&src, &src, &src, &dst, vImage_Flags(kvImageNoFlags))
                guard err == kvImageNoError else { return nil }
                // Copy from the buffer pointer — touching `dstData` inside its own mutable
                // borrow is an exclusivity violation.
                return makeRGB(data: Array(dstBytes.bindMemory(to: UInt8.self)),
                               width: width, height: height, rowBytes: width * 3)
            }
        }
    }

    /// Convenience wrapper — production path: `StereoFrame` carries CGImages, not byte arrays.
    /// Handles any row padding the source CGImage has.
    public static func convert(image: CGImage) -> CGImage? {
        guard image.bitsPerPixel == 8, image.width > 0, image.height > 0 else { return nil }
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: Unmanaged.passRetained(CGColorSpaceCreateDeviceGray()),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent)
        var src = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&src, &format, nil, image,
                                           vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(src.data) }
        let width = image.width, height = image.height
        var dstData = [UInt8](repeating: 0, count: width * 3 * height)
        let result: CGImage? = dstData.withUnsafeMutableBytes { dstBytes -> CGImage? in
            var dst = vImage_Buffer(data: dstBytes.baseAddress,
                                    height: vImagePixelCount(height),
                                    width: vImagePixelCount(width),
                                    rowBytes: width * 3)
            let err = vImageConvert_Planar8toRGB888(&src, &src, &src, &dst, vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { return nil }
            return makeRGB(data: Array(dstBytes.bindMemory(to: UInt8.self)),
                           width: width, height: height, rowBytes: width * 3)
        }
        return result
    }

    private static func makeRGB(data: [UInt8], width: Int, height: Int, rowBytes: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Raw detector output, Vision's own coordinate conventions: normalized points with origin
/// BOTTOM-LEFT, joints in Vision's naming. Internal — only `VisionHandDetector` produces it
/// and only `HandObservationMapper` consumes it.
internal struct RawHandObservation {
    internal var points: [SIMD2<Float>?]      // 21, canonical order, origin bottom-left
    internal var confidences: [Float?]        // 21
    internal var chirality: HandChirality

    internal init(points: [SIMD2<Float>?], confidences: [Float?]? = nil, chirality: HandChirality) {
        self.points = points
        self.confidences = confidences ?? Array(repeating: nil, count: points.count)
        self.chirality = chirality
    }
}

/// Pure mapping from raw Vision observations to the contract: canonical order, y-flip
/// (bottom-left → top-left), missing joints → (0,0) with 0.0 confidence, present joints
/// with nil confidence → 1.0. Internal machinery — only the detector and its tests use it
/// (a public method may not take the internal `RawHandObservation`).
enum HandObservationMapper {
    public static func map(_ raw: RawHandObservation) -> TrackedHand {
        let count = HandJoint.allCases.count
        var landmarks = [SIMD2<Float>](repeating: .zero, count: count)
        var confidences = [Float](repeating: 0, count: count)
        for i in 0..<count {
            guard i < raw.points.count, let p = raw.points[i] else {
                landmarks[i] = .zero
                confidences[i] = 0
                continue
            }
            landmarks[i] = SIMD2<Float>(p.x, 1 - p.y)
            confidences[i] = (i < raw.confidences.count ? raw.confidences[i] : nil) ?? 1.0
        }
        return TrackedHand(landmarks: landmarks, confidences: confidences, chirality: raw.chirality)
    }
}

/// The engine seam — the slot a MediaPipe implementation drops into without touching the
/// contract or the app. Called only on `StereoHandTracker`'s serial queue; implementations
/// are stateless besides the Vision request.
public protocol HandDetecting {
    func detectHands(in image: CGImage) throws -> [TrackedHand]
}

/// Apple Vision hand pose (VNDetectHumanHandPoseRequest): same 21-landmark topology as
/// MediaPipe, zero third-party dependencies, ANE-accelerated.
public struct VisionHandDetector: HandDetecting {
    /// Vision's joint names in canonical `HandJoint` order — the mapping's single source of truth.
    public static let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private let request: VNDetectHumanHandPoseRequest

    public init() {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        self.request = request
    }

    public func detectHands(in image: CGImage) throws -> [TrackedHand] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var hands: [TrackedHand] = []
        hands.reserveCapacity(observations.count)
        for observation in observations {
            var points = [SIMD2<Float>?](repeating: nil, count: Self.jointNames.count)
            var confidences = [Float?](repeating: nil, count: Self.jointNames.count)
            // macOS API shape: recognizedPoints is the renamed
            // recognizedPointsForJointsGroupName:error: method — takes the .all group and throws.
            let pointsByJoint = try observation.recognizedPoints(.all)
            for (i, name) in Self.jointNames.enumerated() {
                guard let p = pointsByJoint[name] else { continue }
                points[i] = SIMD2<Float>(Float(p.location.x), Float(p.location.y))
                confidences[i] = p.confidence
            }
            let chirality: HandChirality
            switch observation.chirality {
            case .left: chirality = .left
            case .right: chirality = .right
            default: chirality = .unknown
            }
            hands.append(HandObservationMapper.map(
                RawHandObservation(points: points, confidences: confidences, chirality: chirality)))
        }
        return hands
    }
}
