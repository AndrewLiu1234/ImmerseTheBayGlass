// XRealProbe — live hardware verification of the raw XREAL frame pipeline.
// Run it from the bundle (dist/XRealMirror.app/Contents/MacOS/XRealProbe) so the app's camera permission applies.
//
//   XRealProbe --devices              list external video devices, exit 0 (no capture, no permission needed)
//   XRealProbe [--frames N] [--out DIR] [--timeout SEC]
//                                     capture N frames (default 40, incl. the 6 StereoCamera skips), verify, dump PNGs
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XRealVision

let banner = "XREAL PROBE"   // the bundle gate (scripts/check-bundle.sh) greps for this exact line
let skippedByCamera = 6     // StereoCamera drops the first 6 warmup frames before the probe sees anything
let pngPairs = 3

// MARK: - Arguments

struct Options {
    var devicesOnly = false
    var frames = 40
    var outDir = "/tmp/xreal-probe"
    var timeout: Double = 15
}

func usage() -> Never {
    print("usage: XRealProbe [--devices] [--frames N] [--out DIR] [--timeout SEC]")
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--devices": o.devicesOnly = true
        case "--frames": guard let v = args.next(), let n = Int(v), n > skippedByCamera else { usage() }; o.frames = n
        case "--out": guard let v = args.next(), !v.isEmpty else { usage() }; o.outDir = v
        case "--timeout": guard let v = args.next(), let t = Double(v), t > 0 else { usage() }; o.timeout = t
        case "-h", "--help": usage()
        default: print("unknown argument: \(a)"); usage()
        }
    }
    return o
}

// MARK: - Helpers

func externalDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
}

func savePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func hex(_ id: UInt8) -> String { String(format: "0x%02X", id) }

/// Waits for camera permission. Returns true when authorized.
func ensureCameraPermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; done.signal() }
        done.wait()
        return granted
    default: return false
    }
}

// MARK: - Capture state (touched from the capture queue, read on main after stop(); guarded by a lock)

final class ProbeState: NSObject, StereoCameraDelegate, @unchecked Sendable {  // all mutable state behind `lock`
    let lock = NSLock()
    let target: Int
    let outDir: URL
    let finished = DispatchSemaphore(value: 0)

    var received = 0
    var decodedOK = 0
    var badSizes: [Int] = []
    var perCamera: [UInt8: Int] = [:]
    var lastSeq: [UInt8: UInt16] = [:]
    var deltasTotal = 0
    var deltas256 = 0
    var badDeltasAfterFirst: [String] = []
    var zeroFractions: [Double] = []
    var pairsSeen = 0
    var pngPaths: [String] = []
    var pngFailures: [String] = []
    private var signalled = false

    init(target: Int, outDir: URL) { self.target = target; self.outDir = outDir }

    func onRaw(_ f: DecodedFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !signalled else { return }
        received += 1
        if f.scan.count == FrameLayout.imageBytes { decodedOK += 1 } else { badSizes.append(f.scan.count) }
        perCamera[f.cameraID, default: 0] += 1
        if let prev = lastSeq[f.cameraID] {
            let delta = (f.sequence &- prev) & 0xFFFF
            deltasTotal += 1
            if delta == 256 { deltas256 += 1 }
            // The first delta per camera after the skip may be anything; every later one must be 256.
            else if perCamera[f.cameraID, default: 0] > 2 {
                badDeltasAfterFirst.append("\(hex(f.cameraID)) \(prev)→\(f.sequence) (Δ\(delta))")
            }
        }
        lastSeq[f.cameraID] = f.sequence
        if zeroFractions.count < 3, !f.scan.isEmpty {
            let zeros = f.scan.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
            zeroFractions.append(Double(zeros) / Double(f.scan.count))
        }
        if received >= target { signalled = true; finished.signal() }
    }

    func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame) {
        lock.lock(); defer { lock.unlock() }
        guard pairsSeen < pngPairs else { return }
        let i = pairsSeen
        pairsSeen += 1
        for (name, eye) in [("left", frame.left), ("right", frame.right)] {
            let url = outDir.appendingPathComponent("\(name)_\(i).png")
            if savePNG(eye.image, to: url) { pngPaths.append(url.path) } else { pngFailures.append(url.path) }
        }
    }
}

// MARK: - Main

let opts = parseOptions()
print(banner)

if opts.devicesOnly {
    let devices = externalDevices()
    if devices.isEmpty { print("  (no external video devices)") }
    for d in devices {
        print("  \(d.localizedName) | modelID: \(d.modelID) | activeFormat: \(d.activeFormat.description)")
    }
    exit(0)
}

guard let device = StereoCamera.findXRealDevice() else {
    print("NO XREAL FOUND")
    let devices = externalDevices()
    print("  external video devices: \(devices.isEmpty ? "none" : devices.map { "\($0.localizedName) (\($0.modelID))" }.joined(separator: ", "))")
    exit(1)
}
print("  device: \(device.localizedName) (\(device.modelID))")

guard ensureCameraPermission() else {
    // macOS checks camera permission for the app that launched this process: Terminal/iTerm when run from a shell,
    // XRealMirror only when launched by the app. A terminal already marked "denied" never gets a new prompt.
    print("PROBE FAIL: camera permission not granted (status: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
    print("  Run from a terminal, the permission belongs to the TERMINAL app: System Settings → Privacy & Security →")
    print("  Camera → enable Terminal (or iTerm, etc.), quit and reopen it, then rerun.")
    print("  To get the prompt back: tccutil reset Camera com.apple.Terminal")
    exit(1)
}

let outURL = URL(fileURLWithPath: opts.outDir)
do {
    try FileManager.default.createDirectory(atPath: outURL.path, withIntermediateDirectories: true)
} catch {
    print("PROBE FAIL: cannot create output directory \(outURL.path): \(error.localizedDescription)")
    exit(1)
}

let target = opts.frames - skippedByCamera
let state = ProbeState(target: target, outDir: outURL)
let camera = StereoCamera()
camera.delegate = state
camera.rawFrameHandler = { [state] f in state.onRaw(f) }
do {
    try camera.start()
} catch {
    print("PROBE FAIL: StereoCamera.start() threw \(error)")
    exit(1)
}
let timedOut = state.finished.wait(timeout: .now() + opts.timeout) == .timedOut
camera.stop()
Thread.sleep(forTimeInterval: 0.2)  // let an in-flight callback on the capture queue finish

state.lock.lock()
var reasons: [String] = []
if state.received == 0 { reasons.append("zero frames decoded") }
if timedOut && state.received > 0 { reasons.append("timed out after \(opts.timeout) s with \(state.received)/\(target) frames") }
if !state.badSizes.isEmpty { reasons.append("decoded image size ≠ \(FrameLayout.imageBytes) bytes: \(Set(state.badSizes).sorted())") }
for id in [CameraID.left, CameraID.right] where state.perCamera[id, default: 0] == 0 {
    reasons.append("camera \(hex(id)) never seen")
}
let unknownIDs = state.perCamera.keys.filter { $0 != CameraID.left && $0 != CameraID.right }.sorted()
if !unknownIDs.isEmpty { reasons.append("unexpected camera IDs: \(unknownIDs.map(hex))") }
if !state.badDeltasAfterFirst.isEmpty {
    reasons.append("sequence delta ≠ 256: \(state.badDeltasAfterFirst.prefix(5).joined(separator: "; "))")
}
if !state.pngFailures.isEmpty { reasons.append("PNG write failed: \(state.pngFailures.joined(separator: ", "))") }
if state.received > 0 && state.pairsSeen == 0 { reasons.append("no stereo pair emitted") }

let cams = state.perCamera.keys.sorted().map { "\(hex($0)) x\(state.perCamera[$0]!)" }.joined(separator: ", ")
print("  frames decoded: \(state.decodedOK) / \(state.received) received (\(state.badSizes.isEmpty ? "all" : "NOT all") 308,480-byte frames → \(FrameLayout.imageBytes)-byte images)")
print("  cameras seen: \(cams.isEmpty ? "none" : cams)")
print("  sequence deltas == 256: \(state.deltas256)/\(state.deltasTotal) same-ID pairs")
print("  first-frame zero fraction: \(state.zeroFractions.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
print("  PNGs: \(state.pngPaths.isEmpty ? "none" : "\(outURL.path)/left_0.png … (\(state.pairsSeen) pairs)")")
state.lock.unlock()

if reasons.isEmpty {
    print("PROBE PASS")
    exit(0)
} else {
    print("PROBE FAIL: \(reasons.joined(separator: " | "))")
    exit(1)
}
