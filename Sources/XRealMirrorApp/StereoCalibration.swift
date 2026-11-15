import simd

/// One XREAL eye camera: equidistant fisheye (OpenCV `fisheye` model) on the UPRIGHT 480x640 image — the same image
/// the hand tracker sees, so tracker pixels go straight in. Camera frame: x right, y down, z forward, metres.
struct FisheyeLens: Sendable {
    let fx, fy, cx, cy: Double
    let k1, k2, k3, k4: Double

    /// Unit ray through `pixel` (inverts the equidistant distortion with Newton's method).
    func unproject(pixel: SIMD2<Double>) -> SIMD3<Double> {
        let x = (pixel.x - cx) / fx, y = (pixel.y - cy) / fy
        let thetaD = (x * x + y * y).squareRoot()
        guard thetaD > 1e-12 else { return SIMD3(0, 0, 1) }
        var theta = min(thetaD, .pi / 2 * 0.999)
        for _ in 0..<20 {
            let t2 = theta * theta
            let f = theta * (1 + t2 * (k1 + t2 * (k2 + t2 * (k3 + t2 * k4)))) - thetaD
            let fp = 1 + t2 * (3 * k1 + t2 * (5 * k2 + t2 * (7 * k3 + t2 * 9 * k4)))
            let step = f / fp
            theta -= step
            if abs(step) < 1e-14 { break }
        }
        let s = sin(theta) / thetaD
        return SIMD3(x * s, y * s, cos(theta))
    }

    /// Pixel of a point in this camera's frame; nil if it's behind the camera.
    func project(_ p: SIMD3<Double>) -> SIMD2<Double>? {
        guard p.z > 0 else { return nil }
        let r = (p.x * p.x + p.y * p.y).squareRoot()
        guard r > 1e-12 else { return SIMD2(cx, cy) }
        let theta = atan2(r, p.z), t2 = theta * theta
        let thetaD = theta * (1 + t2 * (k1 + t2 * (k2 + t2 * (k3 + t2 * k4))))
        return SIMD2(fx * thetaD * p.x / r + cx, fy * thetaD * p.y / r + cy)
    }
}

/// The left/right pair. World frame = the LEFT camera's frame (x right, y down, z forward, metres).
struct StereoCalibration: Sendable {
    let left: FisheyeLens
    let right: FisheyeLens
    /// X_right = rotation * X_left + translation (Kalibr's T_cn_cnm1 for cam1 relative to cam0).
    let rotation: simd_double3x3
    let translation: SIMD3<Double>

    var rightCenterInLeft: SIMD3<Double> { -(rotation.transpose * translation) }

    func leftToRight(_ p: SIMD3<Double>) -> SIMD3<Double> { rotation * p + translation }

    struct Triangulated: Sendable {
        var point: SIMD3<Double>   // left-camera frame, metres
        var rayGap: Double         // closest distance between the two viewing rays, metres (match quality)
    }

    /// Midpoint triangulation of one joint seen at `leftPixel` and `rightPixel` (upright-image pixels).
    /// Nil when the rays are parallel or only meet behind/at the cameras (a mismatched pair).
    func triangulate(leftPixel: SIMD2<Double>, rightPixel: SIMD2<Double>, minDepth: Double = 0.03) -> Triangulated? {
        let d0 = left.unproject(pixel: leftPixel)
        let c1 = rightCenterInLeft
        let d1 = rotation.transpose * right.unproject(pixel: rightPixel)
        // Solve s*d0 - u*d1 ≈ c1 in least squares (closest points on the two rays).
        let a = simd_dot(d0, d0), b = simd_dot(d0, d1), c = simd_dot(d1, d1)
        let e = simd_dot(d0, c1), f = simd_dot(d1, c1)
        let den = a * c - b * b
        guard den > 1e-12 else { return nil }
        let s = (e * c - b * f) / den
        let u = (e * b - a * f) / den
        guard s > minDepth, u > minDepth else { return nil }
        let p0 = s * d0, p1 = c1 + u * d1
        let mid = (p0 + p1) / 2
        guard mid.z > minDepth else { return nil }
        return Triangulated(point: mid, rayGap: simd_distance(p0, p1))
    }

    /// Air 2 Ultra calibration from github.com/vladoshub/xr-gate (MIT), calibration_dataset/final/xreal_air2ultra/
    /// ZBBM5DZFMP/unified_480_ccw90/camchain-camera-only.yaml: cam0 = left eye, cam1 = right eye, 480x640 upright.
    /// It's another unit of the same model — a start value; checked against Andrew's live frames (rays meet within
    /// ~1 cm at hand distance).
    static let xrealAir2Ultra = StereoCalibration(
        left: FisheyeLens(fx: 238.88264329583697, fy: 238.43988669054954, cx: 239.65578750366714, cy: 321.1613847182054,
                          k1: 0.004136165249475896, k2: 0.09509478306213548, k3: -0.11766502639762973, k4: 0.04622914792374395),
        right: FisheyeLens(fx: 238.01314574429594, fy: 237.9290215251219, cx: 238.5959141485548, cy: 318.63275203667945,
                           k1: 0.011015556563154302, k2: 0.06646119044294033, k3: -0.07637866453799633, k4: 0.025620245489721263),
        rotation: simd_double3x3(rows: [
            SIMD3(0.9850136410684377, 0.018619324951571557, -0.1714685033685415),
            SIMD3(-0.018723939284882564, 0.999824184292754, 0.0010072740371973358),
            SIMD3(0.17145711127496513, 0.002218387179408799, 0.9851890873084046),
        ]),
        translation: SIMD3(-0.13596552543221865, 0.0008464566862285916, -0.010657069881313909))
}
