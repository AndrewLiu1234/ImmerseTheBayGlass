import Foundation
import simd
import XRealVision

/// A marker's 3-D pose in the LEFT camera frame (x right, y down, z forward, metres).
struct MarkerPose3D: Sendable {
    enum Source: Sendable, Equatable { case stereo, leftOnly, rightOnly }

    var id: Int
    var center: SIMD3<Double>
    /// Columns: printed-right, printed-down, and their cross product (pointing INTO the surface the marker is on).
    var rotation: simd_double3x3
    var source: Source
    /// RMS corner reprojection error over the eyes used, pixels.
    var reprojectionErrorPx: Double
    /// Side length from triangulating the corners (stereo only) — a free check against the printed 60 mm.
    var triangulatedSide: Double?

    var face: SIMD3<Double> { -rotation.columns.2 }    // out of the printed side
    /// Black-square corners in contract order (printed TL, TR, BR, BL) for a given side length.
    func corners(side: Double = MarkerPoseEstimator.markerSide) -> [SIMD3<Double>] {
        MarkerPoseEstimator.localCorners(side: side).map { rotation * $0 + center }
    }
}

/// Turns per-eye marker detections (Person 1's contract) into 3-D marker poses.
/// Stereo when both eyes see a marker: triangulate corners → rigid-fit the 60 mm square → jointly refine against both
/// eyes' pixels. One eye only: homography initial pose (+ its mirror-ambiguity twin) → refine against that eye.
struct MarkerPoseEstimator: Sendable {
    static let markerSide = 0.060
    static let imageSize = SIMD2<Double>(Double(FrameLayout.uprightWidth), Double(FrameLayout.uprightHeight))

    let calibration: StereoCalibration
    /// A stereo fit is rejected (falls back to the better single eye) above this RMS reprojection error.
    var maxStereoErrorPx = 2.0

    /// Marker-local corners: x = printed right, y = printed down, z = 0; contract order TL, TR, BR, BL.
    static func localCorners(side: Double = markerSide) -> [SIMD3<Double>] {
        let h = side / 2
        return [SIMD3(-h, -h, 0), SIMD3(h, -h, 0), SIMD3(h, h, 0), SIMD3(-h, h, 0)]
    }

    /// Contract normalized (origin top-left, 0…1 over the image) → OpenCV pixel convention (centres at integers).
    static func pixels(_ o: MarkerObservation) -> [SIMD2<Double>] {
        o.corners.map { SIMD2(Double($0.x), Double($0.y)) * imageSize - 0.5 }
    }

    func estimate(left: [MarkerObservation], right: [MarkerObservation]) -> [MarkerPose3D] {
        let l = Dictionary(left.filter { $0.corners.count == 4 }.map { ($0.id, Self.pixels($0)) }, uniquingKeysWith: { a, _ in a })
        let r = Dictionary(right.filter { $0.corners.count == 4 }.map { ($0.id, Self.pixels($0)) }, uniquingKeysWith: { a, _ in a })
        return Set(l.keys).union(r.keys).sorted().compactMap { id in
            switch (l[id], r[id]) {
            case let (lp?, rp?):
                if let s = stereo(id: id, left: lp, right: rp), s.reprojectionErrorPx <= maxStereoErrorPx { return s }
                return [single(id: id, pixels: lp, rightEye: false), single(id: id, pixels: rp, rightEye: true)]
                    .compactMap { $0 }.min { $0.reprojectionErrorPx < $1.reprojectionErrorPx }
            case let (lp?, nil): return single(id: id, pixels: lp, rightEye: false)
            case let (nil, rp?): return single(id: id, pixels: rp, rightEye: true)
            default: return nil
            }
        }
    }

    // MARK: Stereo

    func stereo(id: Int, left: [SIMD2<Double>], right: [SIMD2<Double>]) -> MarkerPose3D? {
        var pts: [SIMD3<Double>] = []
        for k in 0..<4 {
            guard let t = calibration.triangulate(leftPixel: left[k], rightPixel: right[k]) else { return nil }
            pts.append(t.point)
        }
        let side = (0..<4).map { simd_distance(pts[$0], pts[($0 + 1) % 4]) }.reduce(0, +) / 4
        guard let fit = RigidFit.fit(model: Self.localCorners(), observed: pts) else { return nil }
        let refined = refine(rotation: fit.rotation, center: fit.translation, views: [(left, false), (right, true)])
        return MarkerPose3D(id: id, center: refined.center, rotation: refined.rotation, source: .stereo,
                            reprojectionErrorPx: refined.rms, triangulatedSide: side)
    }

    // MARK: Single eye

    func single(id: Int, pixels: [SIMD2<Double>], rightEye: Bool) -> MarkerPose3D? {
        let lens = rightEye ? calibration.right : calibration.left
        // Pinhole-normalized image points of the corner rays (fisheye undone exactly by unproject).
        let m = pixels.map { p -> SIMD2<Double>? in
            let ray = lens.unproject(pixel: p)
            return ray.z > 0.05 ? SIMD2(ray.x / ray.z, ray.y / ray.z) : nil
        }
        guard m.allSatisfy({ $0 != nil }), let h = Homography.fit(plane: Self.localCorners().map { SIMD2($0.x, $0.y) },
                                                                    image: m.map { $0! }) else { return nil }
        // H ≈ λ [r1 r2 c] for X_eye = R·(s, t, 0) + c.
        var h1 = h.columns.0, h2 = h.columns.1, h3 = h.columns.2
        let lambda = (simd_length(h1) + simd_length(h2)) / 2
        guard lambda > 1e-12 else { return nil }
        h1 /= lambda; h2 /= lambda; h3 /= lambda
        if h3.z < 0 { h1 = -h1; h2 = -h2; h3 = -h3 }
        let r1 = simd_normalize(h1)
        let r2 = simd_normalize(h2 - simd_dot(h2, r1) * r1)
        let r0 = simd_double3x3(columns: (r1, r2, simd_cross(r1, r2)))
        // Planar pose ambiguity: the same square seen from one camera fits two tilts (mirrored about the line of
        // sight) almost equally well. Refine both and keep the better.
        let view = simd_normalize(h3)
        let n = r0.columns.2, nFlip = 2 * simd_dot(n, view) * view - n
        let axis = simd_cross(n, nFlip)
        var starts = [r0]
        if simd_length(axis) > 1e-9 {
            let angle = atan2(simd_length(axis), simd_dot(n, nFlip))
            starts.append(simd_double3x3(simd_quatd(angle: angle, axis: simd_normalize(axis))) * r0)
        }
        let eyeViews = [(pixels, rightEye)]
        // Work in the left frame throughout (refine() projects into whichever eye each view belongs to).
        let toLeft = { (r: simd_double3x3, c: SIMD3<Double>) -> (simd_double3x3, SIMD3<Double>) in
            rightEye ? (self.calibration.rotation.transpose * r, self.calibration.rotation.transpose * (c - self.calibration.translation))
                     : (r, c)
        }
        let best = starts.map { start -> (rotation: simd_double3x3, center: SIMD3<Double>, rms: Double) in
            let (r, c) = toLeft(start, h3)
            return refine(rotation: r, center: c, views: eyeViews)
        }.min { $0.rms < $1.rms }!
        return MarkerPose3D(id: id, center: best.center, rotation: best.rotation, source: rightEye ? .rightOnly : .leftOnly,
                            reprojectionErrorPx: best.rms, triangulatedSide: nil)
    }

    // MARK: Refinement (Levenberg–Marquardt on 6-DoF, fisheye pixel residuals, left-frame pose)

    func residuals(rotation: simd_double3x3, center: SIMD3<Double>, views: [([SIMD2<Double>], Bool)]) -> [Double]? {
        var r: [Double] = []
        let local = Self.localCorners()
        for (px, rightEye) in views {
            for k in 0..<4 {
                let pl = rotation * local[k] + center
                let pe = rightEye ? calibration.leftToRight(pl) : pl
                guard let proj = (rightEye ? calibration.right : calibration.left).project(pe) else { return nil }
                r.append(proj.x - px[k].x)
                r.append(proj.y - px[k].y)
            }
        }
        return r
    }

    func refine(rotation: simd_double3x3, center: SIMD3<Double>, views: [([SIMD2<Double>], Bool)],
                iterations: Int = 30) -> (rotation: simd_double3x3, center: SIMD3<Double>, rms: Double) {
        func apply(_ d: [Double], _ r: simd_double3x3, _ c: SIMD3<Double>) -> (simd_double3x3, SIMD3<Double>) {
            let w = SIMD3(d[0], d[1], d[2]), ang = simd_length(w)
            let dr = ang > 1e-15 ? simd_double3x3(simd_quatd(angle: ang, axis: w / ang)) : matrix_identity_double3x3
            return (dr * r, c + SIMD3(d[3], d[4], d[5]))
        }
        func cost(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
        var r = rotation, c = center
        guard var res = residuals(rotation: r, center: c, views: views) else { return (r, c, .infinity) }
        var mu = 1e-3
        for _ in 0..<iterations {
            // Numeric Jacobian (6 params).
            var jac = [[Double]](repeating: [Double](repeating: 0, count: 6), count: res.count)
            for p in 0..<6 {
                let eps = p < 3 ? 1e-6 : 1e-7
                var d = [Double](repeating: 0, count: 6); d[p] = eps
                let (r2, c2) = apply(d, r, c)
                guard let res2 = residuals(rotation: r2, center: c2, views: views) else { continue }
                for i in 0..<res.count { jac[i][p] = (res2[i] - res[i]) / eps }
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6), g = [Double](repeating: 0, count: 6)
            for i in 0..<res.count {
                for p in 0..<6 {
                    g[p] += jac[i][p] * res[i]
                    for q in 0..<6 { a[p][q] += jac[i][p] * jac[i][q] }
                }
            }
            var improved = false
            for _ in 0..<8 {
                var am = a
                for p in 0..<6 { am[p][p] *= 1 + mu; am[p][p] += 1e-12 }
                guard let step = LinearSolve.solve(am, g.map { -$0 }) else { mu *= 10; continue }
                let (r2, c2) = apply(step, r, c)
                if let res2 = residuals(rotation: r2, center: c2, views: views), cost(res2) < cost(res) {
                    r = r2; c = c2; res = res2; mu = max(mu / 10, 1e-9); improved = true
                    break
                }
                mu *= 10
            }
            if !improved || cost(res) < 1e-18 { break }
        }
        // Re-orthonormalize (numerical drift).
        let x = simd_normalize(r.columns.0), y = simd_normalize(r.columns.1 - simd_dot(r.columns.1, x) * x)
        r = simd_double3x3(columns: (x, y, simd_cross(x, y)))
        return (r, c, (cost(res) / Double(res.count / 2)).squareRoot())
    }
}

/// Best-fit rotation + translation taking `model` points onto `observed` (Horn's closed-form quaternion method).
enum RigidFit {
    static func fit(model: [SIMD3<Double>], observed: [SIMD3<Double>], weights: [Double]? = nil)
        -> (rotation: simd_double3x3, translation: SIMD3<Double>, rms: Double)? {
        guard model.count == observed.count, model.count >= 3 else { return nil }
        let w = weights ?? [Double](repeating: 1, count: model.count)
        let wsum = w.reduce(0, +)
        guard wsum > 0 else { return nil }
        let ca = zip(model, w).reduce(SIMD3<Double>.zero) { $0 + $1.0 * $1.1 } / wsum
        let cb = zip(observed, w).reduce(SIMD3<Double>.zero) { $0 + $1.0 * $1.1 } / wsum
        var s = [[Double]](repeating: [0, 0, 0], count: 3)    // s[i][j] = Σ w a_i b_j
        for k in 0..<model.count {
            let a = model[k] - ca, b = observed[k] - cb
            for i in 0..<3 { for j in 0..<3 { s[i][j] += w[k] * a[i] * b[j] } }
        }
        let (sxx, sxy, sxz) = (s[0][0], s[0][1], s[0][2])
        let (syx, syy, syz) = (s[1][0], s[1][1], s[1][2])
        let (szx, szy, szz) = (s[2][0], s[2][1], s[2][2])
        let n: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        // Largest-eigenvalue eigenvector by power iteration on N + shift·I. The shift is the Gershgorin bound — just
        // enough to make the matrix positive semi-definite; a looser shift would slow convergence badly.
        let gershgorinMin = (0..<4).map { i in n[i][i] - (0..<4).filter { $0 != i }.reduce(0) { $0 + abs(n[i][$1]) } }.min()!
        let shift = max(0, -gershgorinMin) + 1e-12
        var q = SIMD4<Double>(1, 0.01, 0.01, 0.01)
        for _ in 0..<1000 {
            var nq = SIMD4<Double>.zero
            for i in 0..<4 { nq[i] = (0..<4).reduce(0) { $0 + n[i][$1] * q[$1] } + shift * q[i] }
            let len = simd_length(nq)
            guard len > 0 else { return nil }
            q = nq / len
        }
        let rot = simd_double3x3(simd_quatd(ix: q[1], iy: q[2], iz: q[3], r: q[0]))
        let t = cb - rot * ca
        let rms = (zip(model, observed).map { simd_distance_squared(rot * $0.0 + t, $0.1) }.reduce(0, +) / Double(model.count)).squareRoot()
        return (rot, t, rms)
    }
}

/// Plane (s, t) → image homography from ≥ 4 correspondences (DLT with h33 = 1; exactly determined for 4 points).
enum Homography {
    static func fit(plane: [SIMD2<Double>], image: [SIMD2<Double>]) -> simd_double3x3? {
        guard plane.count == 4, image.count == 4 else { return nil }
        var a: [[Double]] = [], b: [Double] = []
        for k in 0..<4 {
            let (X, Y, x, y) = (plane[k].x, plane[k].y, image[k].x, image[k].y)
            a.append([X, Y, 1, 0, 0, 0, -x * X, -x * Y]); b.append(x)
            a.append([0, 0, 0, X, Y, 1, -y * X, -y * Y]); b.append(y)
        }
        guard let h = LinearSolve.solve(a, b) else { return nil }
        return simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
    }
}

/// Dense Gaussian elimination with partial pivoting (small systems only).
enum LinearSolve {
    static func solve(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn, b = bIn
        let n = b.count
        for col in 0..<n {
            let piv = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[piv][col]) > 1e-14 else { return nil }
            a.swapAt(col, piv); b.swapAt(col, piv)
            for row in (col + 1)..<n {
                let f = a[row][col] / a[col][col]
                guard f != 0 else { continue }
                for k in col..<n { a[row][k] -= f * a[col][k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let s = ((row + 1)..<n).reduce(0) { $0 + a[row][$1] * x[$1] }
            x[row] = (b[row] - s) / a[row][row]
        }
        return x
    }
}
