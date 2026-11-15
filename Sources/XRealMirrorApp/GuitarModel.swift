import Foundation
import simd

/// Tape numbers from the real guitar (Person 1's Task 2). Distances in metres.
struct GuitarMeasurements: Codable, Equatable, Sendable {
    /// From the midpoint of ID 9's nut-side black-square edge (its printed bottom edge) to the nut centre, along ID 9's
    /// printed-down direction (i.e. along the headstock toward the nut).
    var headstockEdgeToNut: Double
    /// How far the fretboard surface at the nut sits above ID 9's printed face, along that face's normal.
    var headstockFaceToFretboard: Double
    /// Sideways offset of the nut centre from ID 9's centre line, along ID 9's printed-right (+ = treble side).
    var headstockSideways: Double
    /// The fret the centres of ID 7 and ID 8 line up with.
    var bodyMarkersFret: Int
    /// Fretboard surface height above the faces of ID 7/8 (they're on the top, which is lower than the fretboard).
    var fretboardAboveBodyMarkers: Double
    /// Signed sideways offset of the 7/8 centres' midpoint from the neck centre line (+ = treble). From the tape:
    /// (treble-edge→ID 7 gap − bass-edge→ID 8 gap) / 2.
    var bodyMidpointOffsetY: Double

    /// Placeholder until Person 1's tape numbers: read off IMG_3385 and typical acoustic dimensions.
    static let f600Estimate = GuitarMeasurements(headstockEdgeToNut: 0.015, headstockFaceToFretboard: 0.005,
                                                 headstockSideways: 0, bodyMarkersFret: 14,
                                                 fretboardAboveBodyMarkers: 0.009, bodyMidpointOffsetY: 0)
}

/// A specific guitar: where each marker's corners sit in the guitar frame (fretboard spec: origin nut centre on the
/// fretboard surface, +x to the bridge, +y treble, +z out of the fretboard) plus its fretboard spec.
struct GuitarModel: Codable, Equatable, Sendable {
    struct MarkerCorners: Codable, Equatable, Sendable {
        var id: Int
        var corners: [SIMD3<Double>]       // contract order: printed TL, TR, BR, BL
    }

    var name: String
    var spec: Fretboard.Spec
    var markers: [MarkerCorners]
    var measurements: GuitarMeasurements
    /// Distance nut → body-marker fret measured by the cameras minus the scale-length prediction. Large = a tape number
    /// or the calibration is off.
    var scaleCheckError: Double
    /// Worst per-marker RMS corner spread across the capture after outlier rejection.
    var captureSpread: Double
    var framesUsed: Int

    func corners(of id: Int) -> [SIMD3<Double>]? { markers.first { $0.id == id }?.corners }
}

/// Builds a GuitarModel from a still capture: per frame the 3-D marker poses (MarkerPoseEstimator), plus tape.
enum GuitarSetup {
    enum SetupError: Error, Equatable {
        case markerNotSeen(Int)
        case inconsistent(id: Int, spreadMm: Double)
        case bodyMarkersSwapped
    }

    static let requiredIDs = [7, 8, 9]

    static func build(captures: [[MarkerPose3D]], measurements: GuitarMeasurements, spec: Fretboard.Spec,
                      name: String = "Yamaha F600", minFrames: Int = 5, outlierDistance: Double = 0.003,
                      maxSpread: Double = 0.002) throws -> GuitarModel {
        let frames = captures.map { f in Dictionary(f.map { ($0.id, $0.corners()) }, uniquingKeysWith: { a, _ in a }) }
        for id in requiredIDs where frames.filter({ $0[id] != nil }).count < minFrames { throw SetupError.markerNotSeen(id) }

        // 1. Initial map in the frame of a reference marker (8, else 7), from frames that contain it.
        let ref = frames.filter { $0[8] != nil }.count >= minFrames ? 8 : 7
        var samples: [Int: [[SIMD3<Double>]]] = [:]
        for f in frames {
            guard let refCorners = f[ref],
                  let t = RigidFit.fit(model: MarkerPoseEstimator.localCorners(), observed: refCorners) else { continue }
            for (id, cs) in f { samples[id, default: []].append(cs.map { t.rotation.transpose * ($0 - t.translation) }) }
        }
        var (map, spread) = try robustMean(samples, minFrames: minFrames, outlierDistance: outlierDistance)

        // 2. Refine: align every frame to the whole map (all visible corners, so no single marker's angle error is
        //    magnified over the neck), re-average. A few rounds converge.
        for _ in 0..<3 {
            samples = [:]
            for f in frames {
                let ids = f.keys.filter { map[$0] != nil }.sorted()
                guard ids.count >= 2,
                      let t = RigidFit.fit(model: ids.flatMap { map[$0]! }, observed: ids.flatMap { f[$0]! }) else { continue }
                for id in ids { samples[id, default: []].append(f[id]!.map { t.rotation.transpose * ($0 - t.translation) }) }
            }
            (map, spread) = try robustMean(samples, minFrames: minFrames, outlierDistance: outlierDistance)
        }
        if let worst = spread.max(by: { $0.value < $1.value }), worst.value > maxSpread {
            throw SetupError.inconsistent(id: worst.key, spreadMm: worst.value * 1000)
        }

        // 3. Guitar frame, expressed in the map frame.
        func pose(_ id: Int) -> (r: simd_double3x3, c: SIMD3<Double>) {
            let t = RigidFit.fit(model: MarkerPoseEstimator.localCorners(), observed: map[id]!)!
            return (t.rotation, t.translation)
        }
        let p7 = pose(7), p8 = pose(8), p9 = pose(9)
        let face = { (p: (r: simd_double3x3, c: SIMD3<Double>)) in -p.r.columns.2 }
        let z = simd_normalize(face(p7) + face(p8))
        let c9 = map[9]!
        let nut = (c9[2] + c9[3]) / 2 + measurements.headstockEdgeToNut * p9.r.columns.1
            + measurements.headstockFaceToFretboard * face(p9) + measurements.headstockSideways * p9.r.columns.0
        let mid = (p7.c + p8.c) / 2 + measurements.fretboardAboveBodyMarkers * z
        func axes(toward p: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
            var x = p - nut
            x = simd_normalize(x - simd_dot(x, z) * z)
            return (x, simd_cross(z, x))
        }
        var (x, y) = axes(toward: mid)
        let bodyPoint = mid - measurements.bodyMidpointOffsetY * y
        (x, y) = axes(toward: bodyPoint)
        guard simd_dot(p7.c - p8.c, y) > 0 else { throw SetupError.bodyMarkersSwapped }   // ID 7 must be on the treble side

        let r = simd_double3x3(columns: (x, y, z))
        let fret = Fretboard(spec: spec).fretX(measurements.bodyMarkersFret)
        let markers = requiredIDs.map { id in
            GuitarModel.MarkerCorners(id: id, corners: map[id]!.map { r.transpose * ($0 - nut) })
        }
        return GuitarModel(name: name, spec: spec, markers: markers, measurements: measurements,
                           scaleCheckError: simd_dot(bodyPoint - nut, x) - fret,
                           captureSpread: spread.values.max() ?? 0, framesUsed: frames.count)
    }

    /// Per marker: drop samples whose centroid is > outlierDistance from the median centroid, average the rest.
    private static func robustMean(_ samples: [Int: [[SIMD3<Double>]]], minFrames: Int, outlierDistance: Double)
        throws -> (map: [Int: [SIMD3<Double>]], spread: [Int: Double]) {
        var map: [Int: [SIMD3<Double>]] = [:], spread: [Int: Double] = [:]
        for (id, list) in samples {
            let centroids = list.map { $0.reduce(.zero, +) / 4 }
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            let med = SIMD3(median(centroids.map(\.x)), median(centroids.map(\.y)), median(centroids.map(\.z)))
            let kept = zip(list, centroids).filter { simd_distance($0.1, med) <= outlierDistance }.map(\.0)
            guard kept.count >= minFrames else {
                let s = (centroids.map { simd_distance_squared($0, med) }.reduce(0, +) / Double(centroids.count)).squareRoot()
                throw SetupError.inconsistent(id: id, spreadMm: s * 1000)
            }
            let mean = (0..<4).map { k in kept.map { $0[k] }.reduce(.zero, +) / Double(kept.count) }
            map[id] = mean
            let sq = kept.flatMap { cs in (0..<4).map { simd_distance_squared(cs[$0], mean[$0]) } }
            spread[id] = (sq.reduce(0, +) / Double(sq.count)).squareRoot()
        }
        return (map, spread)
    }
}
