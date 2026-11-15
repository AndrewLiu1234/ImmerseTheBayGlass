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
// @unchecked Sendable: CGImage is immutable, and the hot path (pairer, skipCounter,
// delivery in captureOutput) is confined to `queue`. Setup/teardown state (session,
// output, skipCounter reset, started) is touched by start()/stop() on the caller's
// thread, so start/stop must be called from a single thread — which both consumers
// do. The compiler cannot see either discipline, so this conformance is asserted by hand.
public final class StereoCamera: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var delegate: StereoCameraDelegate?
    public var rawFrameHandler: ((DecodedFrame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "com.immersetebay.xrealmirror.capture")   // internal: test seam
    private var pairer = StereoPairer()
    private var skipCounter = 0
    private var started = false

    private static let queueKey = DispatchSpecificKey<UInt8>()

    public override init() {
        super.init()
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

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
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw XRealCameraError.deviceNotFound
        }
        session.addInput(input)
        // videoSettings MUST stay unset: the glasses deliver a raw, unconverted UVC payload
        // (640x241 'yuvs' packaging of the 308,480-byte frame). Asking AVFoundation to convert
        // destroys the frame layout.
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw XRealCameraError.deviceNotFound
        }
        session.addOutput(output)
        session.commitConfiguration()   // startRunning must follow a committed configuration
        output.setSampleBufferDelegate(self, queue: queue)
        skipCounter = 6          // first frames are all zeros (sensor warmup)
        session.startRunning()
        started = true
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            // Already on the capture queue (e.g. called from rawFrameHandler): run inline —
            // queue.sync here would re-enter the serial queue and trap ("BUG IN CLIENT OF
            // LIBDISPATCH: dispatch_sync called on queue already owned by current thread").
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        guard started else { return }   // stop before start is a no-op
        session.stopRunning()
        pairer.reset()
        skipCounter = 6
        started = false
    }

    /// Video sample buffers from AVCaptureVideoDataOutput are image-buffer-backed:
    /// CMSampleBufferGetDataBuffer is nil for them. Reads the full raw payload from
    /// the CVPixelBuffer instead (the device's 640x241 'yuvs' buffer is exactly
    /// FrameLayout.frameBytes bytes).
    static func rawBytes(from sampleBuffer: CMSampleBuffer) -> [UInt8]? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let length = CVPixelBufferGetDataSize(pixelBuffer)
        return Array(UnsafeRawBufferPointer(start: base, count: length))
    }

    nonisolated public func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        // Runs on `queue` (registered in start()); all mutable state is confined to it.
        guard skipCounter == 0 else {
            skipCounter -= 1
            return
        }
        guard let bytes = Self.rawBytes(from: sampleBuffer),
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
