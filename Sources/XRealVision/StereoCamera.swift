import AVFoundation
import CoreGraphics

/// Pairs left/right eye frames by their shared metadata sequence number.
public struct StereoPairer {
    private var pending: [UInt16: RawEyeFrame] = [:]

    public var pendingCount: Int { pending.count }

    public mutating func accept(image: CGImage, sequence: UInt16, cameraID: UInt8,
                                timestampMicros: UInt64) -> StereoFrame? {
        guard cameraID == CameraID.left || cameraID == CameraID.right else { return nil }
        let eye = RawEyeFrame(image: image, cameraID: cameraID,
                              sequence: sequence, timestampMicros: timestampMicros)
        if let waiting = pending[sequence] {
            if waiting.cameraID != cameraID {
                // Other eye for the same sequence arrived earlier: emit the pair.
                pending.removeValue(forKey: sequence)
                let left = waiting.cameraID == CameraID.left ? waiting : eye
                let right = waiting.cameraID == CameraID.right ? waiting : eye
                return StereoFrame(left: left, right: right, sequence: sequence,
                                   timestampMicros: timestampMicros)
            }
            // Duplicate of the same eye for the same sequence: keep the newest.
            pending[sequence] = eye
            return nil
        }
        pending[sequence] = eye
        if pending.count > 8 {
            // Spec: the map is CLEARED when it exceeds 8 pending entries. A backlog that deep
            // means the eye streams have diverged; pairing across it would corrupt sequences.
            pending.removeAll()
        }
        return nil
    }

    public mutating func reset() { pending.removeAll() }
}

public protocol StereoCameraDelegate: AnyObject {
    func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame)
}

public enum XRealCameraError: Error {
    case deviceNotFound
}

/// Thin AVFoundation wrapper over the XREAL UVC device. Delivers `StereoFrame`s and raw decoded
/// frames on its own private serial queue; consumers hop threads. Camera permission is the
/// caller's job, not this class's.
// @unchecked Sendable: CGImage is immutable and all mutable state is confined to `queue`;
// the compiler cannot see the confinement, so this conformance is asserted by hand.
public final class StereoCamera: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var delegate: StereoCameraDelegate?
    public var rawFrameHandler: ((DecodedFrame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.immersetebay.xrealmirror.capture")
    private var pairer = StereoPairer()
    private var skipCounter = 0
    private var started = false

    public static func findXRealDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first {
            $0.localizedName.contains("UVC Camera") || $0.modelID.contains("VendorID_13080")
        }
    }

    public func start() throws {
        guard !started else { return }
        guard let device = Self.findXRealDevice() else { throw XRealCameraError.deviceNotFound }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw XRealCameraError.deviceNotFound }
        session.addInput(input)
        // videoSettings MUST stay unset: the glasses deliver a raw, unconverted UVC payload
        // (640x241 'yuvs' packaging of the 308,480-byte frame). Asking AVFoundation to convert
        // destroys the frame layout.
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw XRealCameraError.deviceNotFound }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        skipCounter = 6          // first frames are all zeros (sensor warmup)
        session.startRunning()
        started = true
    }

    public func stop() {
        queue.sync {
            session.stopRunning()
            pairer.reset()
            skipCounter = 6
            started = false
        }
    }

    nonisolated public func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        // Runs on `queue` (registered in start()); all mutable state is confined to it.
        guard skipCounter == 0 else {
            skipCounter -= 1
            return
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                                destination: &bytes)
        guard status == kCMBlockBufferNoErr,
              let decoded = XRealFrameDecoder.decode(bytes) else { return }
        rawFrameHandler?(decoded)
        if let image = XRealFrameDecoder.makeEyeImage(scan: decoded.scan,
                                                      cameraID: decoded.cameraID),
           let frame = pairer.accept(image: image, sequence: decoded.sequence,
                                     cameraID: decoded.cameraID,
                                     timestampMicros: decoded.timestampMicros) {
            delegate?.stereoCamera(self, didEmit: frame)
        }
    }
}
