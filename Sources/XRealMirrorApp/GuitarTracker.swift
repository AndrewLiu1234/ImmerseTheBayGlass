import Foundation
import simd

/// Where the guitar is: guitar frame (fretboard spec) → LEFT camera frame.
struct GuitarPose: Sendable {
    enum State: Sendable, Equatable { case tracking, holding }

    var rotation: simd_double3x3
    var translation: SIMD3<Double>
    var markersUsed: [Int]
    /// RMS distance between the model's and the observed corners of the markers used, metres.
    var residualRMS: Double
    var state: State

    func toCamera(_ g: SIMD3<Double>) -> SIMD3<Double> { rotation * g + translation }
    func toGuitar(_ c: SIMD3<Double>) -> SIMD3<Double> { rotation.transpose * (c - translation) }
}

/// Live guitar pose from whichever markers are visible each frame: weighted rigid fit of all their corners to the
/// guitar model, a marker that disagrees with the others is dropped, 1€ smoothing, and a short hold when every
/// marker is hidden (e.g. under the strumming arm).
struct GuitarTracker {
    let model: GuitarModel
    var smoothing: Bool
    var holdSeconds = 0.5
    /// A marker whose corners sit further than this (RMS) from the fit is treated as a bad detection.
    var outlierThreshold = 0.005
    /// Single-eye marker poses are less reliable in depth; they count this much per corner versus a stereo pose.
    var singleEyeWeight = 0.25

    private var last: GuitarPose?
    private var lastSeen: TimeInterval = -.infinity
    private var position = OneEuroFilter3()
    private var orientation = OneEuroRotation()

    init(model: GuitarModel, smoothing: Bool = true) {
        self.model = model
        self.smoothing = smoothing
    }

    mutating func update(_ markers: [MarkerPose3D], timestamp: TimeInterval) -> GuitarPose? {
        let usable = markers.filter { model.corners(of: $0.id) != nil }
        guard var fit = Self.fit(usable, model: model, singleEyeWeight: singleEyeWeight) else {
            if var held = last, timestamp - lastSeen <= holdSeconds {
                held.state = .holding
                return held
            }
            reset()
            return nil
        }
        // Drop disagreeing markers one at a time (leave-one-out: keep the subset that fits best).
        var current = usable
        while current.count >= 2, (fit.perMarker.values.max() ?? 0) > outlierThreshold {
            if current.count == 2 {
                // Two markers that disagree: no majority — trust the better-measured one.
                let keep = current.min { a, b in
                    (a.source == .stereo ? 0 : 1, a.reprojectionErrorPx) < (b.source == .stereo ? 0 : 1, b.reprojectionErrorPx)
                }!
                current = [keep]
            } else {
                current = current.indices.map { i in current.enumerated().filter { $0.offset != i }.map(\.element) }
                    .min { (Self.fit($0, model: model, singleEyeWeight: singleEyeWeight)?.rms ?? .infinity)
                         < (Self.fit($1, model: model, singleEyeWeight: singleEyeWeight)?.rms ?? .infinity) }!
            }
            guard let f = Self.fit(current, model: model, singleEyeWeight: singleEyeWeight) else { return nil }
            fit = f
        }

        var r = fit.rotation, t = fit.translation
        if smoothing {
            if last == nil { position = OneEuroFilter3(); orientation = OneEuroRotation() }
            t = position.filter(t, timestamp: timestamp)
            r = simd_double3x3(orientation.filter(simd_quatd(r), timestamp: timestamp))
        }
        let pose = GuitarPose(rotation: r, translation: t, markersUsed: current.map(\.id).sorted(),
                              residualRMS: fit.rms, state: .tracking)
        last = pose
        lastSeen = timestamp
        return pose
    }

    private mutating func reset() {
        last = nil
        position = OneEuroFilter3()
        orientation = OneEuroRotation()
    }

    struct Fit {
        var rotation: simd_double3x3
        var translation: SIMD3<Double>
        var rms: Double
        var perMarker: [Int: Double]
    }

    static func fit(_ markers: [MarkerPose3D], model: GuitarModel, singleEyeWeight: Double) -> Fit? {
        var modelPts: [SIMD3<Double>] = [], obs: [SIMD3<Double>] = [], w: [Double] = [], owner: [Int] = []
        for m in markers {
            guard let mc = model.corners(of: m.id) else { continue }
            let oc = m.corners()
            modelPts += mc
            obs += oc
            w += [Double](repeating: m.source == .stereo ? 1 : singleEyeWeight, count: 4)
            owner += [Int](repeating: m.id, count: 4)
        }
        guard modelPts.count >= 4, let f = RigidFit.fit(model: modelPts, observed: obs, weights: w) else { return nil }
        var sq: [Int: (Double, Int)] = [:]
        for i in modelPts.indices {
            let d2 = simd_distance_squared(f.rotation * modelPts[i] + f.translation, obs[i])
            sq[owner[i], default: (0, 0)].0 += d2
            sq[owner[i], default: (0, 0)].1 += 1
        }
        return Fit(rotation: f.rotation, translation: f.translation, rms: f.rms,
                   perMarker: sq.mapValues { ($0.0 / Double($0.1)).squareRoot() })
    }
}

/// 1€ filter for an orientation: slerp toward the new rotation with a cutoff that rises with angular speed.
struct OneEuroRotation {
    var minCutoff = 1.0
    var beta = 0.05
    var derivativeCutoff = 1.0

    private var value: simd_quatd?
    private var speed = 0.0
    private var lastTimestamp: TimeInterval = 0

    mutating func filter(_ q: simd_quatd, timestamp: TimeInterval) -> simd_quatd {
        guard let prev = value else {
            value = q
            lastTimestamp = timestamp
            return q
        }
        let dt = timestamp - lastTimestamp
        guard dt > 0 else { return prev }
        var qn = q
        if simd_dot(prev.vector, qn.vector) < 0 { qn = simd_quatd(vector: -qn.vector) }   // same hemisphere
        let rel = qn * prev.inverse
        let angle = 2 * atan2(simd_length(rel.imag), abs(rel.real))
        speed += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (angle / dt - speed)
        let out = simd_slerp(prev, qn, Self.alpha(cutoff: minCutoff + beta * speed, dt: dt))
        value = out
        lastTimestamp = timestamp
        return out
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff) / dt) }
}
