import CoreGraphics
import Foundation
import Accelerate
import simd
import XRealVision

/// 8-bit grayscale image, row-major, top row first. Pixel (u, v) has its centre at (u, v) (OpenCV convention).
struct ProtoGrayImage: Sendable {
    var width: Int, height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Any CGImage → 8-bit gray (fast path copies an 8-bit gray image's rows directly).
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h)
        if image.bitsPerPixel == 8, image.bitsPerComponent == 8, image.colorSpace?.model == .monochrome,
           image.decode == nil, let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (h - 1) + w {
            let bpr = image.bytesPerRow
            px.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w, base + y * bpr, w) }
            }
        } else {
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if !ok { return nil }
        }
        self.init(width: w, height: h, pixels: px)
    }
}

/// One decoded marker in pixel coordinates (OpenCV convention), contract corner order.
struct ProtoPixelMarker: Sendable {
    var id: Int
    var corners: [SIMD2<Double>]
    var hammingDistance: Int
}

/// Competing prototype ArUco detector for IDs 7/8/9 (4×4 data bits + 1-cell black border).
///
/// Pipeline (no Vision): box-mean adaptive threshold → run-length 8-connected components of dark pixels →
/// convex hull of each component's outer boundary → max-area inscribed quad → sub-pixel edge refinement
/// (mid-level crossings along each side's normal, quadratic fit per side to follow fisheye curvature, curve
/// intersection at the corners) → homography bit sampling → dictionary match under the 4 rotations
/// (Hamming ≤ 1). Mirrored markers never match a rotation because quads are always wound clockwise on screen
/// (but see the tests: IDs 8 and 9 are transpose-symmetric, so their mirror images *are* rotations).
struct PrototypeMarkerDetector: MarkerDetecting, Sendable {
    var maxHamming = 1
    /// Adaptive-threshold offset (gray levels below the local mean to count as dark).
    var thresholdOffset = 7
    /// Minimum white-vs-black cell contrast to accept a decode.
    var minContrast = 25.0

    func detectMarkers(in image: CGImage) throws -> [MarkerObservation] {
        guard let g = ProtoGrayImage(image) else { return [] }
        let w = Double(g.width), h = Double(g.height)
        return detectPixelMarkers(in: g).map { m in
            MarkerObservation(id: m.id,
                              corners: m.corners.map { SIMD2(Float(($0.x + 0.5) / w), Float(($0.y + 0.5) / h)) },
                              hammingDistance: m.hammingDistance)
        }
    }

    func detectPixelMarkers(in g: ProtoGrayImage) -> [ProtoPixelMarker] {
        detect(g).map(\.marker)
    }

    /// Detections plus whether sub-pixel refinement succeeded (false = coarse hull corners, ~1 px accuracy).
    func detect(_ g: ProtoGrayImage) -> [(marker: ProtoPixelMarker, refined: Bool)] {
        guard g.width >= 16, g.height >= 16 else { return [] }
        let scale = Double(max(g.width, g.height)) / 640
        let radius = max(3, Int((5 * scale).rounded()))
        let minSide = 7.0 * max(1, scale * 0.5)
        var best: [Int: (marker: ProtoPixelMarker, refined: Bool, score: Double)] = [:]
        for comp in darkComponents(g, radius: radius) {
            guard let coarse = fitQuad(comp.boundary, minSide: minSide), looksLikeMarker(g, coarse) else { continue }
            let fine = refineQuad(g, coarse)
            let quad = fine ?? coarse
            guard let (id, ham, rot, contrast) = decode(g, quad) else { continue }
            let corners = (0..<4).map { quad[($0 + rot) % 4] }
            let score = contrast - 30 * Double(ham) + (fine != nil ? 100 : 0)
            if let prev = best[id], prev.score >= score { continue }
            best[id] = (ProtoPixelMarker(id: id, corners: corners, hammingDistance: ham), fine != nil, score)
        }
        return best.keys.sorted().map { (best[$0]!.marker, best[$0]!.refined) }
    }

    // MARK: - Threshold + connected components

    struct Component {
        var boundary: [SIMD2<Double>]   // pixel-square corners of each run's ends (hull of these = hull of blob)
    }

    func darkComponents(_ g: ProtoGrayImage, radius r: Int) -> [Component] {
        let w = g.width, h = g.height
        // Local box mean (vImage, edge-extended), then dark = pixel + offset < mean.
        var mean = [UInt8](repeating: 0, count: w * h)
        var src = g.pixels
        let k = UInt32(2 * r + 1)
        src.withUnsafeMutableBytes { sb in
            mean.withUnsafeMutableBytes { db in
                var s = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var d = vImage_Buffer(data: db.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                _ = vImageBoxConvolve_Planar8(&s, &d, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        // Runs of dark pixels.
        var runY: [Int32] = [], runX0: [Int32] = [], runX1: [Int32] = []
        runY.reserveCapacity(8192); runX0.reserveCapacity(8192); runX1.reserveCapacity(8192)
        var rowStart = [Int](repeating: 0, count: h + 1)
        let c = Int16(thresholdOffset)
        g.pixels.withUnsafeBufferPointer { px in
            mean.withUnsafeBufferPointer { mb in
                for y in 0..<h {
                    rowStart[y] = runY.count
                    let row = y * w
                    var inRun = false
                    var start = 0
                    for x in 0..<w {
                        let dark = Int16(px[row + x]) + c < Int16(mb[row + x])
                        if dark != inRun {
                            if dark { start = x } else {
                                runY.append(Int32(y)); runX0.append(Int32(start)); runX1.append(Int32(x - 1))
                            }
                            inRun = dark
                        }
                    }
                    if inRun { runY.append(Int32(y)); runX0.append(Int32(start)); runX1.append(Int32(w - 1)) }
                }
                rowStart[h] = runY.count
            }
        }
        // Union-find over runs, 8-connected.
        let n = runY.count
        var parent = [Int32](0..<Int32(n))
        func find(_ i: Int32) -> Int32 {
            var i = i
            while parent[Int(i)] != i { parent[Int(i)] = parent[Int(parent[Int(i)])]; i = parent[Int(i)] }
            return i
        }
        for y in 1..<max(h, 1) {
            var j = rowStart[y - 1]
            let jEnd = rowStart[y]
            for i in rowStart[y]..<rowStart[y + 1] {
                while j < jEnd && runX1[j] < runX0[i] - 1 { j += 1 }
                var k = j
                while k < jEnd && runX0[k] <= runX1[i] + 1 {
                    let a = find(Int32(i)), b = find(Int32(k))
                    if a != b { parent[Int(max(a, b))] = min(a, b) }
                    k += 1
                }
            }
        }
        // Aggregate bounding boxes.
        var minX = [Int32](repeating: .max, count: n), maxX = [Int32](repeating: -1, count: n)
        var minY = [Int32](repeating: .max, count: n), maxY = [Int32](repeating: -1, count: n)
        var count = [Int32](repeating: 0, count: n)
        var root = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let p = Int(find(Int32(i)))
            root[i] = Int32(p)
            minX[p] = min(minX[p], runX0[i]); maxX[p] = max(maxX[p], runX1[i])
            minY[p] = min(minY[p], runY[i]); maxY[p] = max(maxY[p], runY[i])
            count[p] += runX1[i] - runX0[i] + 1
        }
        let minSize: Int32 = 7, maxSize = Int32(Double(max(w, h)) * 0.6)
        var keep = [Int32](repeating: -1, count: n)
        var comps: [Component] = []
        for p in 0..<n where parent[p] == Int32(p) {
            let bw = maxX[p] - minX[p] + 1, bh = maxY[p] - minY[p] + 1
            guard bw >= minSize, bh >= minSize, bw <= maxSize, bh <= maxSize, count[p] >= 20,
                  minX[p] > 0, minY[p] > 0, maxX[p] < Int32(w - 1), maxY[p] < Int32(h - 1) else { continue }
            keep[p] = Int32(comps.count)
            comps.append(Component(boundary: []))
        }
        // Per component and row, only the leftmost and rightmost dark pixel matter for the convex hull.
        var rowY = [[Int32]](repeating: [], count: comps.count)
        var rowMin = [[Int32]](repeating: [], count: comps.count), rowMax = [[Int32]](repeating: [], count: comps.count)
        for i in 0..<n {
            let k = Int(keep[Int(root[i])])
            guard k >= 0 else { continue }
            if let last = rowY[k].last, last == runY[i] {
                let j = rowY[k].count - 1
                rowMin[k][j] = min(rowMin[k][j], runX0[i]); rowMax[k][j] = max(rowMax[k][j], runX1[i])
            } else {
                rowY[k].append(runY[i]); rowMin[k].append(runX0[i]); rowMax[k].append(runX1[i])
            }
        }
        for k in 0..<comps.count {
            var pts: [SIMD2<Double>] = []
            pts.reserveCapacity(rowY[k].count * 4)
            for j in 0..<rowY[k].count {
                let y = Double(rowY[k][j]), a = Double(rowMin[k][j]) - 0.5, b = Double(rowMax[k][j]) + 0.5
                pts += [SIMD2(a, y - 0.5), SIMD2(a, y + 0.5), SIMD2(b, y - 0.5), SIMD2(b, y + 0.5)]
            }
            comps[k].boundary = pts
        }
        return comps
    }

    // MARK: - Quad fit

    private static func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Andrew's monotone chain; returns hull wound clockwise on screen (y down) = positive shoelace.
    private static func convexHull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper   // counter-clockwise in math axes = clockwise on screen
    }

    static func signedArea2(_ q: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in 0..<q.count { let a = q[i], b = q[(i + 1) % q.count]; s += a.x * b.y - b.x * a.y }
        return s
    }

    func fitQuad(_ boundary: [SIMD2<Double>], minSide: Double) -> [SIMD2<Double>]? {
        var hull = Self.convexHull(boundary)
        guard hull.count >= 4 else { return nil }
        let hullArea = Self.signedArea2(hull) / 2
        guard hullArea > minSide * minSide * 0.5 else { return nil }
        // Thin the hull to ≤ 24 vertices (keep the most significant ones) to bound the O(n³) search.
        while hull.count > 24 {
            var worst = 0, worstVal = Double.infinity
            for i in 0..<hull.count {
                let a = hull[(i + hull.count - 1) % hull.count], b = hull[i], c = hull[(i + 1) % hull.count]
                let v = abs(Self.cross(a, b, c))
                if v < worstVal { worstVal = v; worst = i }
            }
            hull.remove(at: worst)
        }
        let n = hull.count
        var bestArea = 0.0, bestQuad = [0, 1, 2, 3]
        for i in 0..<n {
            for j in (i + 2)..<(i + n - 1) {
                let jj = j % n
                var bk = -1, bkv = 0.0
                for k in (i + 1)..<j { let v = Self.cross(hull[i], hull[k % n], hull[jj]); if v > bkv { bkv = v; bk = k % n } }
                var bl = -1, blv = 0.0
                for l in (j + 1)..<(i + n) { let v = Self.cross(hull[jj], hull[l % n], hull[i]); if v > blv { blv = v; bl = l % n } }
                guard bk >= 0, bl >= 0 else { continue }
                if bkv + blv > bestArea { bestArea = bkv + blv; bestQuad = [i, bk, jj, bl] }
            }
        }
        // hull is CW on screen; with i < k < j < l the quad is also CW.
        let q = bestQuad.map { hull[$0] }
        guard bestArea / 2 >= 0.65 * hullArea else { return nil }
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            guard simd_distance(a, b) >= minSide * 0.5 else { return nil }
            let u = simd_normalize(a - b), v = simd_normalize(c - b)
            let cosang = simd_dot(u, v)
            guard abs(cosang) < 0.94 else { return nil }   // angles within ~20°…160°
        }
        let s0 = simd_distance(q[0], q[1]) + simd_distance(q[2], q[3])
        let s1 = simd_distance(q[1], q[2]) + simd_distance(q[3], q[0])
        guard max(s0, s1) >= 2 * minSide else { return nil }
        return q
    }

    // MARK: - Sub-pixel refinement

    @inline(__always)
    private static func sample(_ g: ProtoGrayImage, _ x: Double, _ y: Double) -> Double {
        let xc = min(max(x, 0), Double(g.width - 1) - 1e-9), yc = min(max(y, 0), Double(g.height - 1) - 1e-9)
        let x0 = Int(xc), y0 = Int(yc)
        let fx = xc - Double(x0), fy = yc - Double(y0)
        return g.pixels.withUnsafeBufferPointer { p in
            let i = y0 * g.width + x0
            let a = Double(p[i]), b = Double(p[i + 1]), c = Double(p[i + g.width]), d = Double(p[i + g.width + 1])
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
    }

    /// A side as a quadratic curve in its own frame: p(s) = origin + s·d + (a + b s + c s²)·n.
    private struct SideCurve {
        var origin: SIMD2<Double>, d: SIMD2<Double>, n: SIMD2<Double>
        var a = 0.0, b = 0.0, c = 0.0
        func point(_ s: Double) -> SIMD2<Double> { origin + s * d + (a + b * s + c * s * s) * n }
        func tangent(_ s: Double) -> SIMD2<Double> { simd_normalize(d + (b + 2 * c * s) * n) }
        func param(_ p: SIMD2<Double>) -> Double { simd_dot(p - origin, d) }
    }

    /// Edge points along side A→B: the outer black/white edge crossing along the outward normal.
    func edgePoints(_ g: ProtoGrayImage, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> [SIMD2<Double>] {
        let len = simd_distance(a, b)
        let d = (b - a) / len
        let n = SIMD2(d.y, -d.x)              // outward for a clockwise-on-screen quad
        let cell = len / 6
        let rIn = min(max(0.45 * cell, 1.2), 4.0), rOut = min(max(0.6 * cell, 1.5), 4.0)
        let step = 0.25
        let count = Int(min(max(len / 1.0, 6), 80))
        let margin = max(0.08 * len, 1.5)
        var pts: [SIMD2<Double>] = []
        pts.reserveCapacity(count)
        var prof = [Double](repeating: 0, count: 64)
        for k in 0..<count {
            let s = margin + (len - 2 * margin) * Double(k) / Double(count - 1)
            let base = a + s * d
            let m = Int(((rIn + rOut) / step).rounded()) + 1
            guard m <= prof.count else { continue }
            for i in 0..<m {
                let o = -rIn + Double(i) * step
                let p = base + o * n
                prof[i] = Self.sample(g, p.x, p.y)
            }
            // Plateaus from the profile's extremes: robust to a narrow paper margin or a dark object beyond it.
            var dark = prof[0], light = prof[0]
            for i in 1..<m { dark = min(dark, prof[i]); light = max(light, prof[i]) }
            guard light - dark > 15 else { continue }
            let level = (dark + light) / 2
            // Crossing closest to the current edge estimate (offset 0).
            var bestO = Double.nan, bestDist = Double.infinity
            for i in 0..<(m - 1) where (prof[i] - level) * (prof[i + 1] - level) <= 0 && prof[i] != prof[i + 1] {
                let t = (level - prof[i]) / (prof[i + 1] - prof[i])
                let o = -rIn + (Double(i) + t) * step
                if abs(o) < bestDist { bestDist = abs(o); bestO = o }
            }
            guard bestO.isFinite else { continue }
            pts.append(base + bestO * n)
        }
        return pts
    }

    private func fitSide(_ pts: [SIMD2<Double>], _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SideCurve? {
        guard pts.count >= 4 else { return nil }
        let len = simd_distance(a, b)
        let d = (b - a) / len
        var curve = SideCurve(origin: a, d: d, n: SIMD2(d.y, -d.x))
        var use = [Bool](repeating: true, count: pts.count)
        let quadratic = pts.count >= 8 && len >= 30
        for pass in 0..<2 {
            // Least squares o = a + b s (+ c s²), s scaled to [0,1] for conditioning.
            var ata = simd_double3x3(0), atb = SIMD3<Double>(repeating: 0)
            var used = 0
            for (i, p) in pts.enumerated() where use[i] {
                let s = simd_dot(p - a, d) / len, o = simd_dot(p - a, curve.n)
                let row = SIMD3(1, s, quadratic ? s * s : 0)
                ata += simd_double3x3(rows: [row * row.x, row * row.y, row * row.z])
                atb += row * o
                used += 1
            }
            guard used >= 4 else { return nil }
            if !quadratic { ata[2][2] = 1 }
            let x = ata.inverse * atb
            guard x.x.isFinite, x.y.isFinite, x.z.isFinite else { return nil }
            curve.a = x.x; curve.b = x.y / len; curve.c = quadratic ? x.z / (len * len) : 0
            if pass == 0 {
                var res: [Double] = []
                for p in pts {
                    let s = simd_dot(p - a, d), o = simd_dot(p - a, curve.n)
                    res.append(abs(o - (curve.a + curve.b * s + curve.c * s * s)))
                }
                let med = res.sorted()[res.count / 2]
                let lim = max(0.35, 3 * 1.4826 * med)
                for i in 0..<pts.count { use[i] = res[i] <= lim }
            }
        }
        return curve
    }

    private static func intersect(_ p: SIMD2<Double>, _ u: SIMD2<Double>, _ q: SIMD2<Double>, _ v: SIMD2<Double>) -> SIMD2<Double>? {
        let den = u.x * v.y - u.y * v.x
        guard abs(den) > 1e-9 else { return nil }
        let t = ((q.x - p.x) * v.y - (q.y - p.y) * v.x) / den
        return p + t * u
    }

    func refineQuad(_ g: ProtoGrayImage, _ coarse: [SIMD2<Double>]) -> [SIMD2<Double>]? {
        var q = coarse
        for _ in 0..<2 {
            var curves: [SideCurve] = []
            for i in 0..<4 {
                let a = q[i], b = q[(i + 1) % 4]
                guard let c = fitSide(edgePoints(g, a, b), a, b) else { return nil }
                curves.append(c)
            }
            var next = q
            for i in 0..<4 {
                let prev = curves[(i + 3) % 4], cur = curves[i]   // corner i = end of prev, start of cur
                var p = q[i]
                for _ in 0..<4 {
                    let sp = prev.param(p), sc = cur.param(p)
                    guard let x = Self.intersect(prev.point(sp), prev.tangent(sp), cur.point(sc), cur.tangent(sc)) else { return nil }
                    p = x
                }
                guard simd_distance(p, q[i]) < max(3, 0.15 * simd_distance(q[i], q[(i + 1) % 4])) else { return nil }
                next[i] = p
            }
            q = next
        }
        return q
    }

    // MARK: - Decode

    /// Homography mapping unit-grid (u, v) ∈ [0,6]² onto the quad (q0 at (0,0), q1 at (6,0), …).
    private static func homography(_ q: [SIMD2<Double>]) -> [Double]? {
        let src: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(6, 0), SIMD2(6, 6), SIMD2(0, 6)]
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (src[i].x, src[i].y, q[i].x, q[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            var piv = col
            for r in col..<8 where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            guard abs(m[piv][col]) > 1e-12 else { return nil }
            m.swapAt(col, piv)
            for r in 0..<8 where r != col {
                let f = m[r][col] / m[col][col]
                if f != 0 { for k in col..<9 { m[r][k] -= f * m[col][k] } }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] } + [1]
    }

    private static func apply(_ h: [Double], _ u: Double, _ v: Double) -> SIMD2<Double> {
        let w = h[6] * u + h[7] * v + h[8]
        return SIMD2((h[0] * u + h[1] * v + h[2]) / w, (h[3] * u + h[4] * v + h[5]) / w)
    }

    private static func rotateCW(_ a: [[Bool]]) -> [[Bool]] {
        let n = a.count
        return (0..<n).map { r in (0..<n).map { c in a[n - 1 - c][r] } }
    }

    private static let rotatedCodes: [(id: Int, rots: [[[Bool]]])] = ArucoDictionary.markers.keys.sorted().map { id in
        var rs = [ArucoDictionary.markers[id]!]
        for _ in 0..<3 { rs.append(rotateCW(rs.last!)) }
        return (id, rs)
    }

    /// Cheap pre-check on the coarse quad before refinement: the black border ring must be clearly darker than
    /// the paper just outside it, and the interior must contain some white (all codes have white bits).
    func looksLikeMarker(_ g: ProtoGrayImage, _ q: [SIMD2<Double>]) -> Bool {
        guard let h = Self.homography(q) else { return false }
        var border: [Double] = [], paper: [Double] = [], inner: [Double] = []
        border.reserveCapacity(20); paper.reserveCapacity(24); inner.reserveCapacity(16)
        for k in 0..<6 {
            let t = Double(k) + 0.5
            for (u, v) in [(t, 0.5), (5.5, t), (6 - t, 5.5), (0.5, 6 - t)] {
                let p = Self.apply(h, u, v); border.append(Self.sample(g, p.x, p.y))
            }
            for (u, v) in [(t, -0.6), (6.6, t), (6 - t, 6.6), (-0.6, 6 - t)] {
                let p = Self.apply(h, u, v); paper.append(Self.sample(g, p.x, p.y))
            }
        }
        for r in 1...4 { for c in 1...4 { let p = Self.apply(h, Double(c) + 0.5, Double(r) + 0.5); inner.append(Self.sample(g, p.x, p.y)) } }
        border.sort(); paper.sort()
        let b = border[border.count / 2], w = paper[paper.count / 2]
        guard w - b >= 0.6 * minContrast else { return false }
        return (inner.max() ?? 0) > b + 0.4 * (w - b)
    }

    /// Returns (id, hamming, k, contrast): observed grid = printed rotated clockwise k times,
    /// so the printed top-left corner is quad corner k.
    func decode(_ g: ProtoGrayImage, _ q: [SIMD2<Double>]) -> (Int, Int, Int, Double)? {
        guard let h = Self.homography(q) else { return nil }
        var cells = [Double](repeating: 0, count: 36)
        let offs = [-0.22, 0, 0.22]
        for r in 0..<6 {
            for c in 0..<6 {
                var s = 0.0
                for dv in offs { for du in offs {
                    let p = Self.apply(h, Double(c) + 0.5 + du, Double(r) + 0.5 + dv)
                    s += Self.sample(g, p.x, p.y)
                } }
                cells[r * 6 + c] = s / Double(offs.count * offs.count)
            }
        }
        // Paper ring just outside the black square.
        var paper: [Double] = []
        for k in 0..<6 {
            let t = Double(k) + 0.5
            for (u, v) in [(t, -0.6), (6.6, t), (6 - t, 6.6), (-0.6, 6 - t)] {
                let p = Self.apply(h, u, v)
                paper.append(Self.sample(g, p.x, p.y))
            }
        }
        paper.sort()
        let paperMedian = paper[paper.count / 2]
        // Two-means threshold over the 36 cells.
        var thr = (cells.min()! + cells.max()!) / 2
        var lo = 0.0, hi = 0.0
        for _ in 0..<5 {
            var sl = 0.0, nl = 0, sh = 0.0, nh = 0
            for v in cells { if v < thr { sl += v; nl += 1 } else { sh += v; nh += 1 } }
            guard nl > 0, nh > 0 else { return nil }
            lo = sl / Double(nl); hi = sh / Double(nh)
            thr = (lo + hi) / 2
        }
        guard hi - lo >= minContrast, paperMedian > thr else { return nil }
        var borderErrors = 0
        for r in 0..<6 { for c in 0..<6 where r == 0 || r == 5 || c == 0 || c == 5 { if cells[r * 6 + c] > thr { borderErrors += 1 } } }
        guard borderErrors <= 1 else { return nil }
        let bits = (0..<4).map { r in (0..<4).map { c in cells[(r + 1) * 6 + c + 1] > thr } }
        var best: (Int, Int, Int)? = nil
        for code in Self.rotatedCodes {
            for (k, pattern) in code.rots.enumerated() {
                var dist = 0
                for r in 0..<4 { for c in 0..<4 where pattern[r][c] != bits[r][c] { dist += 1 } }
                if dist <= maxHamming && (best == nil || dist < best!.1) { best = (code.id, dist, k) }
            }
        }
        guard let best else { return nil }
        return (best.0, best.1, best.2, hi - lo)
    }
}
