import simd
@testable import XRealMirrorApp

/// Synthetic marker poses for the fixture guitar (FixtureGuitar) — for setup/tracker tests that don't need images.
enum GuitarTestSupport {
    static func rotation(_ m: MarkerPlacement) -> simd_double3x3 {
        simd_double3x3(columns: (m.right, m.down, simd_cross(m.right, m.down)))
    }

    /// Marker poses as the estimator would report them with the guitar at (r, t) in the left camera frame,
    /// perturbed by Gaussian noise (position σ metres, angle σ radians).
    static func markerPoses(guitarRotation r: simd_double3x3, translation t: SIMD3<Double>, ids: Set<Int> = [7, 8, 9],
                            posSigma: Double = 0, angSigma: Double = 0, rng: inout SplitMix64,
                            source: MarkerPose3D.Source = .stereo) -> [MarkerPose3D] {
        FixtureGuitar.markers.filter { ids.contains($0.id) }.map { m in
            let p = m.transformed(r, t)
            var rot = rotation(p)
            if angSigma > 0 {
                let axis = simd_normalize(SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()))
                rot = simd_double3x3(simd_quatd(angle: angSigma * rng.gaussian(), axis: axis)) * rot
            }
            let c = p.center + posSigma * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
            return MarkerPose3D(id: m.id, center: c, rotation: rot, source: source, reprojectionErrorPx: 0.2,
                                triangulatedSide: 0.060)
        }
    }

    /// A random plausible guitar pose in front of the glasses.
    static func randomGuitarPose(_ rng: inout SplitMix64) -> (simd_double3x3, SIMD3<Double>) {
        let axis = simd_normalize(SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()))
        let r = simd_double3x3(simd_quatd(angle: rng.uniform(0...3.1), axis: axis))
        return (r, SIMD3(rng.uniform(-0.2...0.2), rng.uniform(0...0.3), rng.uniform(0.3...0.7)))
    }

    /// Tape measurements that exactly match the fixture guitar's layout (what a perfect tape would read).
    static var exactMeasurements: GuitarMeasurements {
        let m9 = FixtureGuitar.markers.first { $0.id == 9 }!
        let edge = (m9.corners()[2] + m9.corners()[3]) / 2          // printed bottom edge = nut side
        let toNut = SIMD3<Double>(0, 0, 0) - edge
        let m7 = FixtureGuitar.markers.first { $0.id == 7 }!
        return GuitarMeasurements(
            headstockEdgeToNut: simd_dot(toNut, m9.down), headstockFaceToFretboard: simd_dot(toNut, m9.face),
            headstockSideways: simd_dot(toNut, m9.right),
            bodyMarkersFret: 14, fretboardAboveBodyMarkers: -(m7.center.z), bodyMidpointOffsetY: 0)
    }

    /// Fretboard points that matter for fingering: nut and frets 1–12 on the centre line, guitar frame.
    static var fingeringPoints: [SIMD3<Double>] {
        let f = Fretboard(spec: .yamahaF600)
        return (0...12).map { SIMD3(f.fretX($0), 0, 0) }
    }
}
