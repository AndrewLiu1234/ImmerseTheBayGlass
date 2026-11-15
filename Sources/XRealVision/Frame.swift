import CoreGraphics

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
