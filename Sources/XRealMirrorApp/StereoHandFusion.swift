import simd
import XRealVision

/// One hand in 3D, in the LEFT camera's frame (x right, y down, z forward, metres).
struct Hand3D: Sendable {
    enum Side: Sendable { case left, right }

    var joints: [SIMD3<Double>]        // 21, canonical HandJoint order
    var meanRayGap: Double             // how closely the two eyes' rays met, averaged over joints (match quality)
    var side: Side                     // the user's left/right, from geometry (Vision's chirality is unreliable here)
    /// Palm frame: column 0 = little→index knuckles, column 1 = wrist→middle knuckle, column 2 = their cross product.
    var orientation: simd_quatd

    var wrist: SIMD3<Double> { joints[HandJoint.wrist.rawValue] }
}

/// Turns the tracker's two 2-D views of the same moment into 3-D hands: pairs each left-eye hand with the right-eye
/// hand that is geometrically consistent with it, then triangulates all 21 joints. Pure and cheap (≈42 ray solves
/// per pair of hands), so it runs on main alongside the overlay update.
struct StereoHandFusion: Sendable {
    let calibration: StereoCalibration
    /// A pairing is accepted only if its viewing rays meet within this, on average. Wrong pairings measured on the
    /// live frames either fail to triangulate or land behind / right at the glasses.
    var maxMeanRayGap = 0.03
    /// Plausible wrist depth range for hands in front of the glasses. The lower bound also rejects cross pairings,
    /// which on the live frames landed ~6 cm from the cameras; real hands were at ~25 cm.
    var depthRange = 0.10...1.5
    var minTriangulatedJoints = 15

    static let imageWidth = Double(FrameLayout.uprightWidth), imageHeight = Double(FrameLayout.uprightHeight)

    func fuse(_ hands: StereoHands) -> [Hand3D] { fuse(left: hands.leftEye.hands, right: hands.rightEye.hands) }

    func fuse(left leftEye: [TrackedHand], right rightEye: [TrackedHand]) -> [Hand3D] {
        let lefts = leftEye.filter { $0.landmarks.count == 21 }
        let rights = rightEye.filter { $0.landmarks.count == 21 }
        guard !lefts.isEmpty, !rights.isEmpty else { return [] }

        // Score every (left, right) pair, then choose the one-to-one assignment that fuses the MOST hands, breaking
        // ties by total ray gap. Greedy smallest-gap-first is wrong: a cross pairing can "meet" close to the glasses
        // with a smaller gap than the true pairs and block both real hands (StereoHandFusionTests regression).
        let candidates: [[Candidate?]] = lefts.map { l in rights.map { r in candidate(l, r) } }
        var best: [Candidate] = []
        var bestGap = Double.infinity
        func search(_ i: Int, _ used: Set<Int>, _ chosen: [Candidate], _ gap: Double) {
            if i == candidates.count {
                if chosen.count > best.count || (chosen.count == best.count && gap < bestGap) { best = chosen; bestGap = gap }
                return
            }
            search(i + 1, used, chosen, gap)                       // left hand i unmatched
            for (j, c) in candidates[i].enumerated() where !used.contains(j) {
                if let c { search(i + 1, used.union([j]), chosen + [c], gap + c.meanRayGap) }
            }
        }
        search(0, [], [], 0)                                       // ≤2×2 hands from Vision: trivially small
        let result = best
        return label(result)
    }

    private struct Candidate { var joints: [SIMD3<Double>]; var meanRayGap: Double }

    private func candidate(_ l: TrackedHand, _ r: TrackedHand) -> Candidate? {
        var points = [SIMD3<Double>?](repeating: nil, count: 21)
        var gaps: [Double] = []
        for i in 0..<21 {
            if let t = calibration.triangulate(leftPixel: pixel(l.landmarks[i]), rightPixel: pixel(r.landmarks[i])) {
                points[i] = t.point
                gaps.append(t.rayGap)
            }
        }
        guard gaps.count >= minTriangulatedJoints else { return nil }
        let meanGap = gaps.reduce(0, +) / Double(gaps.count)
        guard meanGap <= maxMeanRayGap else { return nil }
        // Joints that didn't triangulate: put them on their left-eye ray at the hand's median depth.
        let depths = points.compactMap { $0.map(simd_length) }.sorted()
        let median = depths[depths.count / 2]
        let joints = (0..<21).map { i in
            points[i] ?? calibration.left.unproject(pixel: pixel(l.landmarks[i])) * median
        }
        guard depthRange.contains(joints[HandJoint.wrist.rawValue].z) else { return nil }
        return Candidate(joints: joints, meanRayGap: meanGap)
    }

    private func pixel(_ p: SIMD2<Float>) -> SIMD2<Double> {
        SIMD2(Double(p.x) * Self.imageWidth, Double(p.y) * Self.imageHeight)
    }

    /// Two hands: the one further left (smaller x) is the user's left. One hand: which side of the glasses' centre
    /// line it's on.
    private func label(_ cs: [Candidate]) -> [Hand3D] {
        let midline = calibration.rightCenterInLeft.x / 2
        let sorted = cs.sorted { $0.joints[0].x < $1.joints[0].x }
        return sorted.enumerated().map { idx, c in
            let side: Hand3D.Side = sorted.count >= 2 ? (idx == 0 ? .left : .right) : (c.joints[0].x < midline ? .left : .right)
            return Hand3D(joints: c.joints, meanRayGap: c.meanRayGap, side: side, orientation: Self.palmFrame(c.joints))
        }
    }

    static func palmFrame(_ j: [SIMD3<Double>]) -> simd_quatd {
        let wrist = j[HandJoint.wrist.rawValue]
        let forward = simd_normalize(j[HandJoint.middleMCP.rawValue] - wrist)
        var across = j[HandJoint.indexMCP.rawValue] - j[HandJoint.littleMCP.rawValue]
        across -= simd_dot(across, forward) * forward              // orthogonalize against forward
        guard simd_length(across) > 1e-9, forward.x.isFinite else { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        across = simd_normalize(across)
        let normal = simd_cross(across, forward)
        return simd_quatd(simd_double3x3(columns: (across, forward, normal)))
    }
}
