# XRealMirror — Design

**Date:** 2026-11-14
**Status:** Design agreed in conversation (user opted out of design Q&A and directed: detailed plan, split into 2 parallel workers, pushed to the repo).

## Intent

A from-scratch macOS app whose entire job is to show, live, what both XREAL Air 2 Ultra tracking cameras see — left and right, side by side — and nothing else. It is the first code in the `ImmerseTheBayGlass` repo and proves the glasses' camera pipeline end-to-end on this Mac (UVC capture → block descramble → per-eye rotation → stereo pairing → display).

## Goals

- Live, side-by-side view of the left (`0x20`) and right (`0x21`) feeds, correctly oriented, sustaining the full ~30 stereo pairs/s the hardware delivers.
- Ships as a double-clickable `.app` with working camera TCC permission.
- A probe CLI that verifies the decode pipeline against the actual plugged-in glasses and dumps sample PNGs for human judgment.

## Non-goals (explicitly excluded by the user)

Hand tracking (Vision), calibration dump (HID IMU / fisheye624), 3D lifting, webcam fallback, recording, overlays, or any feature beyond mirroring. If one appears, it is scope creep — stop and ask.

## Anti-goals

- Shipping mirrored or mis-oriented images (the transpose trap).
- An unbundled binary that cannot reliably get camera permission.
- Guessing at any hardware constant the guide pins.

## Constraints (verbatim from the guide)

| Constraint | Value |
|---|---|
| Device | VID `0x3318` (13080), PID `0x0426` (1062); UVC interface 4, bulk endpoint `0x84` |
| Native format | `640x241 'yuvs' @ 59.99988 fps`, `dwMaxVideoFrameBufferSize` = 308,480 bytes |
| Frame layout | 307,200-byte image payload (128 blocks × 2,400 bytes, permuted) + 640-byte metadata row at offset 307,200 + 640 bytes of constant `0x5C` padding at 307,840 (total 308,480 = 640×482) |
| Block map | `reorderMap`: a permutation of 0..<128 (128 values, see `FrameLayout.reorderMap`); logical block `t` is stored in raw block `reorderMap[(align + t) % 128]` |
| Align recovery | Per raw block `b`, sum its first 128 bytes; the block with the smallest sum is logical block 0 (sync, black vignette); `align = inverseMap[sync]` |
| Orientation | Sensor buffer is column-major 640×480. Left (`0x20`): rotate 90° CCW → `upright[639-r][c] = scan[c*640+r]`. Right (`0x21`): rotate 90° CW → `upright[r][479-c] = scan[c*640+r]`. Use `Accelerate` `vImageRotate90_Planar8` with `kRotate90DegreesCounterClockwise` / `kRotate90DegreesClockwise`. A plain transpose produces a mirrored image. |
| Metadata | Offsets from byte 307,200: `+0x00..07` uint64 LE nanoseconds (unused); `+0x12..13` uint16 LE sequence, shared by both frames of a stereo pair, steps 256 per pair; `+0x3A` uint8 camera ID (`0x20` left, `0x21` right) — **not** `+0x3B`; `+0x3E..45` uint64 LE microseconds (same for both cameras) |
| Capture | Discover via `AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)` matching `localizedName.contains("UVC Camera") || modelID.contains("VendorID_13080")`. **Never set `videoSettings`** on `AVCaptureVideoDataOutput` — raw payload must arrive unconverted. |
| Warmup | First 3–4 frames are all zeros; skip the first 6 frames. Auto-exposure converges over ~25 frames. |
| Pairing | `pending: [UInt16: EyeFrame]` keyed by sequence; clear the map if `pending.count > 8`; emit once both `0x20` and `0x21` arrive for the same sequence. |
| Decode budget | Under 16.7 ms per frame in debug builds (vImage rotation keeps it there). |
| Dead ends (do not retry) | Plain 640×480 with 1280-byte header; stacked 640×240 frames; row deinterleaving; field splitting; serpentine scan; YUY2 plane separation; RAW10 unpacking; column-major transpose |

Toolchain: Swift 6.3.3, Xcode 26.6, macOS 26.5.1 (host), deployment target macOS 15.0. TCC: the app must be a bundled `.app` with `NSCameraUsageDescription`; the probe runs **from inside the same bundle** so permission applies to it too.

## Approaches

1. **Chosen — Swift 6 / SwiftUI macOS app, SwiftPM package, `.app` bundle, decoder built from the guide from scratch.** Native AVFoundation path for the raw UVC payload; Accelerate for rotation; unit-testable pure decode core; thin, live-verified capture wrapper.
2. Rejected — porting the guide's repository: user said "start anew".
3. Rejected — Python/OpenCV: not an app, unbundled-process TCC is flaky, slower iteration on a GUI.
4. Rejected — Unity: wrong tool for a raw-UVC mirror; no access to AVFoundation's raw-payload path.

## Architecture

```
USB UVC (640x241 'yuvs' @ 60fps, alternating eyes)
  └─ StereoCamera (AVFoundation, raw payload, no videoSettings, skip first 6)
       └─ XRealFrameDecoder.decode: recoverAlign → unpermute 128 blocks → metadata parse
            └─ makeEyeImage: vImageRotate90 CCW (0x20) / CW (0x21) → 480x640 CGImage
                 └─ StereoPairer (by seq, clear > 8)
                      └─ StereoFrame(left, right) → app: two CALayer-backed panes + status bar
XRealProbe (bundled CLI): same pipeline + hexdumps, layout checks, PNG dumps, PASS/FAIL verdict
```

## Package layout & Task 0 (coordinator pre-step, done before either lane starts)

`Package.swift` (verbatim, do not edit — report to coordinator if it needs a change):

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "XRealMirror",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "XRealVision"),
        .executableTarget(name: "XRealMirrorApp", dependencies: ["XRealVision"]),
        .executableTarget(name: "XRealProbe", dependencies: ["XRealVision"]),
        .testTarget(name: "XRealVisionTests", dependencies: ["XRealVision"]),
    ]
)
```

`.gitignore` (verbatim):

```
.build/
dist/
.DS_Store
.swiftpm/
```

Placeholders (created by coordinator so `swift build` is green before the lanes start; the owning lane deletes its own in its first task):

- `Sources/XRealVision/Lane1Placeholder.swift` — comment-only file.
- `Sources/XRealMirrorApp/main.swift` — `print("XRealMirror placeholder")`.
- `Sources/XRealProbe/main.swift` — `print("XRealProbe placeholder")`.

## Lane split & file ownership

| Path | Owner |
|---|---|
| `Sources/XRealVision/**` | Person 1 (Vision Core) |
| `Tests/XRealVisionTests/**` | Person 1 |
| `Sources/XRealMirrorApp/**` | Person 2 (App & Probe) |
| `Sources/XRealProbe/**` | Person 2 |
| `Resources/Info.plist`, `scripts/**`, `README.md`, `CLAUDE.md` | Person 2 |
| `Package.swift`, `.gitignore`, `docs/**` | Coordinator |

**Hard rule:** a lane must not create or modify files outside its ownership. If a needed change crosses the boundary, finish the task, report it, and let the coordinator fix it. Commit per task, on `main`, in the shared working tree (both lanes edit disjoint paths, so no merge conflicts; if git reports `index.lock` held by the other lane, wait and retry).

## Interface contract (single source of truth — both lanes code against exactly this)

```swift
// Frame.swift
public enum CameraID {
    public static let left: UInt8 = 0x20
    public static let right: UInt8 = 0x21
}
public struct RawEyeFrame {
    public let image: CGImage         // 480x640, 8-bit greyscale, upright, correctly rotated
    public let cameraID: UInt8        // CameraID.left or .right
    public let sequence: UInt16
    public let timestampMicros: UInt64
}
public struct StereoFrame {
    public let left: RawEyeFrame      // cameraID == 0x20
    public let right: RawEyeFrame     // cameraID == 0x21
    public let sequence: UInt16
    public let timestampMicros: UInt64
}

// FrameDecoder.swift
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
    public static let reorderMap: [Int]   // 128 values, verbatim from the guide (see Lane 1 Task 1)
}
public struct DecodedFrame {
    public let scan: [UInt8]           // 307,200 bytes, block-unpermuted, still column-major
    public let align: Int              // 0..<128, recovered
    public let sequence: UInt16        // uint16 LE at metadataOffset + 0x12
    public let cameraID: UInt8         // uint8 at metadataOffset + 0x3A
    public let timestampMicros: UInt64 // uint64 LE at metadataOffset + 0x3E
}
public enum XRealFrameDecoder {
    public static func decode(_ frame: [UInt8]) -> DecodedFrame?
    public static func recoverAlign(payload: [UInt8]) -> Int?
    public static func unpermute(payload: [UInt8], align: Int) -> [UInt8]
    public static func rotateLeft(_ scan: [UInt8]) -> [UInt8]
    public static func rotateRight(_ scan: [UInt8]) -> [UInt8]
    public static func makeCGImage(upright: [UInt8]) -> CGImage?
    public static func makeEyeImage(scan: [UInt8], cameraID: UInt8) -> CGImage?
    public static func encode(upright: [UInt8], cameraID: UInt8, sequence: UInt16,
                              align: Int, timestampMicros: UInt64) -> [UInt8] // inverse, test oracle
}

// StereoCamera.swift
public struct StereoPairer {
    public var pendingCount: Int { pending.count }
    public mutating func accept(image: CGImage, sequence: UInt16, cameraID: UInt8,
                                timestampMicros: UInt64) -> StereoFrame?
    public mutating func reset()
}
public protocol StereoCameraDelegate: AnyObject {
    func stereoCamera(_ camera: StereoCamera, didEmit frame: StereoFrame)
}
public enum XRealCameraError: Error {
    case deviceNotFound
}
public final class StereoCamera: NSObject {
    public weak var delegate: StereoCameraDelegate?
    public var rawFrameHandler: ((DecodedFrame) -> Void)? // per decoded eye-frame, on the capture queue
    public static func findXRealDevice() -> AVCaptureDevice?
    public func start() throws          // throws XRealCameraError.deviceNotFound
    public func stop()
}
```

Contract notes:
- `StereoCamera` delivers delegate callbacks on its own private serial dispatch queue; consumers hop to `DispatchQueue.main` themselves.
- Camera permission is **not** StereoCamera's job — the app owns the permission flow (status check → request → start).
- Swift 6 language mode is on: concurrency-safe code only; annotate the camera class `@unchecked Sendable` with a comment (`CGImage` is immutable).

## Run order

1. Coordinator: Task 0 scaffold, `swift build` green, commit.
2. Person 1 (Vision Core) and Person 2 (App & Probe) in parallel, each committing per task and never committing a broken build.
3. Integration (coordinator): whole-package `swift test`; `scripts/check-bundle.sh`; run the bundled probe against the plugged-in glasses; user judges the probe's PNGs by eye (orientation is a visual fact — observation 225's lesson); final commit + push.
4. Launch the app for the user's live verdict.

Shared-tree notes: SwiftPM serializes concurrent builds against one `.build` (a build that blocks on the lock is normal — wait, don't kill). Both lanes must keep the package compiling at every commit because each builds the whole package.

## Hazards

- Never set `videoSettings` on the capture output (raw payload required).
- Camera ID lives at `+0x3A`, not `+0x3B`.
- Transpose ≠ rotation (mirror trap).
- Skip the first 6 frames; brightness settles over ~25 frames.
- Pairing map clears when `pending.count > 8`.
- Sequence steps 256 per pair (wraps every 256 pairs — the pending map is too small to see a wrap collision).
- The probe must run from the bundled `.app` path for TCC; unbundled `swift run` camera access is flaky.
- The reorderMap is guarded by a permutation unit test (Lane 1 Task 1): if it fails, **stop and report** — the constant was transcribed wrong, don't invent a value.
