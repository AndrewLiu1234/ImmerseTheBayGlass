import Foundation
import simd

/// Re-fits the left→right extrinsics (rotation + translation) of a specific pair of glasses from square markers of
/// known size seen by both eyes — the stereo calibration we ship came from another unit. Lens intrinsics are kept.
///
/// Block-coordinate bundle adjustment: (1) each marker's pose from the LEFT eye alone (scale from the known 60 mm
/// side, independent of the extrinsics); (2) solve the 6-DoF extrinsics that best reproject those markers into the
/// RIGHT eye; (3) re-fit every marker against both eyes with the new extrinsics; repeat (2)–(3), dropping views that
/// don't fit (mismatched corners).
enum StereoSelfCalibration {
    struct Observation: Sendable {
        var id: Int
        var left: [SIMD2<Double>]       // OpenCV pixel convention, contract corner order
        var right: [SIMD2<Double>]
    }

    /// One matched image point seen by both eyes (e.g. the same hand joint), OpenCV pixel convention. Unknown depth:
    /// it constrains the epipolar geometry (rotation, direction of the baseline) but not the scale.
    struct PointPair: Sendable {
        var left: SIMD2<Double>
        var right: SIMD2<Double>
    }

    struct Result: Sendable {
        var calibration: StereoCalibration
        var rmsBefore: Double           // joint stereo reprojection RMS with the starting calibration, px
        var rmsAfter: Double
        var observationsUsed: Int
    }

    /// `points`: matched points spread across the image (hand joints). Markers from only a few spots can't pin all six
    /// extrinsic DoF (a vertical shift trades off against tilt); spread points fix that, the markers fix the scale.
    static func fit(_ observations: [Observation], points: [PointPair] = [], pointWeight: Double = 0.5,
                    start: StereoCalibration, rounds: Int = 6, outlierFactor: Double = 3) -> Result? {
        var cal = start
        // (1) Left-eye-only poses: independent of the extrinsics we're fitting.
        let est0 = MarkerPoseEstimator(calibration: start)
        var obs: [(o: Observation, r: simd_double3x3, c: SIMD3<Double>)] = observations.compactMap { o in
            guard o.left.count == 4, o.right.count == 4,
                  let p = est0.single(id: o.id, pixels: o.left, rightEye: false), p.reprojectionErrorPx < 2 else { return nil }
            return (o, p.rotation, p.center)
        }
        guard obs.count >= 3 else { return nil }
        let rmsBefore = jointRMS(obs.map(\.o), cal: start)
        // Rays of the matched points in each eye's own frame (intrinsics are fixed, so compute once).
        var rays = points.map { (l: start.left.unproject(pixel: $0.left), r: start.right.unproject(pixel: $0.right), p: $0) }

        for round in 0..<rounds {
            // (2) Extrinsics with marker poses fixed.
            cal = solveExtrinsics(obs, rays: rays, pointWeight: pointWeight, start: cal)
            // (3) Every marker against both eyes.
            let est = MarkerPoseEstimator(calibration: cal)
            var errs: [Double] = []
            obs = obs.map { e in
                let f = est.refine(rotation: e.r, center: e.c, views: [(e.o.left, false), (e.o.right, true)])
                errs.append(f.rms)
                return (e.o, f.rotation, f.center)
            }
            // Drop views far worse than typical (after the first round, so a bad start can't evict good views).
            if round >= 1 {
                let median = errs.sorted()[errs.count / 2]
                let keep = zip(obs, errs).filter { $0.1 <= max(outlierFactor * median, 0.5) }.map(\.0)
                if keep.count >= 3 { obs = keep }
                if !rays.isEmpty {
                    let pe = rays.map { pointResidual($0, cal: cal).map { $0 * $0 }.reduce(0, +).squareRoot() }
                    let pm = pe.sorted()[pe.count / 2]
                    let kept = zip(rays, pe).filter { $0.1 <= max(outlierFactor * pm, 2) }.map(\.0)
                    if kept.count >= 10 { rays = kept }
                }
            }
        }
        return Result(calibration: cal, rmsBefore: rmsBefore, rmsAfter: jointRMS(obs.map(\.o), cal: cal),
                      observationsUsed: obs.count)
    }

    /// Mean over views of the per-view joint (both-eye) stereo pose reprojection RMS.
    static func jointRMS(_ observations: [Observation], cal: StereoCalibration) -> Double {
        let est = MarkerPoseEstimator(calibration: cal)
        let e = observations.compactMap { o -> Double? in
            guard let p = est.single(id: o.id, pixels: o.left, rightEye: false) else { return nil }
            return est.refine(rotation: p.rotation, center: p.center, views: [(o.left, false), (o.right, true)]).rms
        }
        return e.isEmpty ? .nan : e.reduce(0, +) / Double(e.count)
    }

    /// LM over 6 parameters (rotation vector applied on the left of R, translation offset) with markers fixed.
    /// Reprojection residual (4 px values) of a matched point: triangulate from the two rays, project into both eyes.
    static func pointResidual(_ q: (l: SIMD3<Double>, r: SIMD3<Double>, p: PointPair), cal: StereoCalibration) -> [Double] {
        let c1 = cal.rightCenterInLeft, d0 = q.l, d1 = cal.rotation.transpose * q.r
        let a = simd_dot(d0, d0), b = simd_dot(d0, d1), c = simd_dot(d1, d1), e = simd_dot(d0, c1), f = simd_dot(d1, c1)
        let den = a * c - b * b
        guard den > 1e-12 else { return [20, 20, 20, 20] }
        let s = (e * c - b * f) / den, u = (e * b - a * f) / den
        guard s > 0.03, u > 0.03 else { return [20, 20, 20, 20] }
        let pt = (s * d0 + c1 + u * d1) / 2
        guard let pl = cal.left.project(pt), let pr = cal.right.project(cal.leftToRight(pt)) else { return [20, 20, 20, 20] }
        return [pl.x - q.p.left.x, pl.y - q.p.left.y, pr.x - q.p.right.x, pr.y - q.p.right.y]
    }

    private static func solveExtrinsics(_ obs: [(o: Observation, r: simd_double3x3, c: SIMD3<Double>)],
                                        rays: [(l: SIMD3<Double>, r: SIMD3<Double>, p: PointPair)], pointWeight: Double,
                                        start: StereoCalibration) -> StereoCalibration {
        let local = MarkerPoseEstimator.localCorners()
        let worldPts = obs.map { e in local.map { e.r * $0 + e.c } }
        func apply(_ d: [Double], _ cal: StereoCalibration) -> StereoCalibration {
            let w = SIMD3(d[0], d[1], d[2]), a = simd_length(w)
            let dr = a > 1e-15 ? simd_double3x3(simd_quatd(angle: a, axis: w / a)) : matrix_identity_double3x3
            return StereoCalibration(left: cal.left, right: cal.right, rotation: dr * cal.rotation,
                                     translation: cal.translation + SIMD3(d[3], d[4], d[5]))
        }
        func residuals(_ cal: StereoCalibration) -> [Double] {
            var r: [Double] = []
            for (i, e) in obs.enumerated() {
                for k in 0..<4 {
                    if let p = cal.right.project(cal.leftToRight(worldPts[i][k])) {
                        r += [p.x - e.o.right[k].x, p.y - e.o.right[k].y]
                    } else { r += [50, 50] }
                }
            }
            let w = pointWeight.squareRoot()
            for q in rays { r += pointResidual(q, cal: cal).map { $0 * w } }
            return r
        }
        func cost(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
        var cal = start, res = residuals(cal), mu = 1e-3
        for _ in 0..<40 {
            var jac = [[Double]](repeating: [Double](repeating: 0, count: 6), count: res.count)
            for p in 0..<6 {
                var d = [Double](repeating: 0, count: 6); d[p] = p < 3 ? 1e-6 : 1e-7
                let r2 = residuals(apply(d, cal))
                for i in 0..<res.count { jac[i][p] = (r2[i] - res[i]) / d[p] }
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6), g = [Double](repeating: 0, count: 6)
            for i in 0..<res.count { for p in 0..<6 { g[p] += jac[i][p] * res[i]; for q in 0..<6 { a[p][q] += jac[i][p] * jac[i][q] } } }
            var improved = false
            for _ in 0..<8 {
                var am = a
                for p in 0..<6 { am[p][p] *= 1 + mu; am[p][p] += 1e-12 }
                guard let step = LinearSolve.solve(am, g.map { -$0 }) else { mu *= 10; continue }
                let c2 = apply(step, cal), r2 = residuals(c2)
                if cost(r2) < cost(res) { cal = c2; res = r2; mu = max(mu / 10, 1e-9); improved = true; break }
                mu *= 10
            }
            if !improved { break }
        }
        // Keep the rotation exactly orthonormal.
        let q = simd_normalize(simd_quatd(cal.rotation))
        return StereoCalibration(left: cal.left, right: cal.right, rotation: simd_double3x3(q), translation: cal.translation)
    }
}
