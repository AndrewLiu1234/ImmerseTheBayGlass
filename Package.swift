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
        .testTarget(name: "XRealMirrorAppTests", dependencies: ["XRealMirrorApp"]),
    ]
)
