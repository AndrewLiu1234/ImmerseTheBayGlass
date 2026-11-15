import CoreGraphics
import Foundation
import simd

/// ArUco marker detector for the XREAL eye cameras.
///
/// Candidate finding is contour-based, NOT Apple Vision's rectangle detector. Vision fundamentally
/// cannot find the steep-angle markers: at 46–77° incidence a square projects to a strongly sheared
/// parallelogram (measured corner angles 32°–149°, aspect ratios up to 4.65), which fails Vision's
/// 30° quadrature tolerance no matter how loose it is configured. A contour finder sees the black
/// square as a dark blob regardless of shear.
///
/// The finder runs on a 4×-downsampled grayscale: adaptive (local-mean) threshold → dark connected
/// components → convex hull → quadrilateral. Adaptive thresholding is what isolates a marker whose
/// black square would otherwise merge with the mid-tone background under a global threshold (marker
/// black ≈ 20, guitar/room ≈ 64: a global Otsu threshold sits above both and fuses them, while a
/// local mean makes the locally-uniform background "light"). Bit decode is the real filter.
///
/// - Decode: homography → 6×6 grid sample → black border ring check → dictionary match over the
///   four rotations with Hamming ≤ 1.
/// - Corner refinement: per edge, sub-pixel step localization from perpendicular gradient profiles,
///   line-fit, adjacent-line intersection.
public struct MarkerDetector: MarkerDetecting {

    public init() {}

    public func detectMarkers(in image: CGImage) throws -> [MarkerObservation] {
        let gray = try GrayBuffer(image)
        var results: [MarkerObservation] = []
        for quad in quadCandidates(in: gray) {
            guard let obs = decodeAndRefine(quad, in: gray) else { continue }
            let isDuplicate = results.contains {
                $0.id == obs.id && simd_length($0.corners[0] - obs.corners[0]) < 5.0 / Float(gray.width)
            }
            if !isDuplicate { results.append(obs) }
        }
        return results
    }

    // MARK: - candidate finding

    private let downsampleFactor = 1
    private let adaptiveWindow = 51       // full-res pixels
    private let adaptiveConstant = 10.0

    func quadCandidates(in gray: GrayBuffer) -> [[SIMD2<Double>]] {
        let f = downsampleFactor
        let coarse = gray.downsampled(factor: f)
        let mask = adaptiveThresholdMask(coarse, window: adaptiveWindow, c: adaptiveConstant)
        let components = connectedComponents(mask: mask, width: coarse.width, height: coarse.height)

        var quads: [[SIMD2<Double>]] = []
        for component in components {
            // Area at full resolution: markers are 15–50 px black squares (hull ~150–2500 px²)
            // plus the unit test's 100 px paper-marker (~10000 px²).
            let fullArea = component.count * f * f
            guard fullArea >= 100, fullArea <= 30000 else { continue }
            // Hull in coarse space, then map the 4 corners to full-res coordinates.
            let coarsePts = component.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
            let hull = convexHull(coarsePts)
            guard hull.count >= 4 else { continue }
            let coarseQuad = simplifyToQuad(hull)
            let fullQuad = coarseQuad.map { SIMD2<Double>($0.x * Double(f), $0.y * Double(f)) }
            quads.append(canonicalQuad(fullQuad))
        }
        return quads
    }

    /// Box-filter (integral image) adaptive threshold. A pixel darker than its local mean minus `c`
    /// is "dark" (marker black); locally uniform regions (paper, background) are "light".
    func adaptiveThresholdMask(_ gray: GrayBuffer, window: Int, c: Double) -> [Bool] {
        let w = gray.width, h = gray.height
        let stride = w + 1
        var integral = [Int64](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: Int64 = 0
            let pBase = y * w
            for x in 0..<w {
                rowSum += Int64(gray.pixels[pBase + x])
                integral[(y + 1) * stride + (x + 1)] = integral[y * stride + (x + 1)] + rowSum
            }
        }
        let half = window / 2
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y1 = max(0, y - half), y2 = min(h, y + half + 1)
            let pBase = y * w
            for x in 0..<w {
                let x1 = max(0, x - half), x2 = min(w, x + half + 1)
                let sum = integral[y2 * stride + x2] - integral[y1 * stride + x2]
                        - integral[y2 * stride + x1] + integral[y1 * stride + x1]
                let area = (y2 - y1) * (x2 - x1)
                let mean = Double(sum) / Double(area)
                mask[pBase + x] = Double(gray.pixels[pBase + x]) < mean - c
            }
        }
        return mask
    }

    /// Labels the true pixels of a binary mask into 4-connected components (union-find, path
    /// halving). Returns each component as its list of pixel coordinates.
    func connectedComponents(mask: [Bool], width w: Int, height h: Int) -> [[SIMD2<Int>]] {
        let n = w * h
        var parent = [Int32](repeating: -1, count: n)

        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != Int32(i) {
                parent[i] = parent[Int(parent[i])]
                i = Int(parent[i])
            }
            return i
        }

        for y in 0..<h {
            let row = y * w
            for x in 0..<w where mask[row + x] {
                let i = row + x
                parent[i] = Int32(i)
                if x > 0 && parent[row + x - 1] >= 0 {
                    let ra = find(i), rb = find(row + x - 1)
                    if ra != rb { parent[ra] = Int32(rb) }
                }
                if y > 0 && parent[row - w + x] >= 0 {
                    let ra = find(i), rb = find(row - w + x)
                    if ra != rb { parent[ra] = Int32(rb) }
                }
            }
        }

        var components: [Int: [SIMD2<Int>]] = [:]
        for i in 0..<n where parent[i] >= 0 {
            let r = find(i)
            components[r, default: []].append(SIMD2<Int>(i % w, i / w))
        }
        return Array(components.values)
    }

    /// Convex hull of a component, simplified to the 4 dominant corners.
    func quadFrom(component: [SIMD2<Int>]) -> [SIMD2<Double>]? {
        let pts = component.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let hull = convexHull(pts)
        guard hull.count >= 4 else { return nil }
        return simplifyToQuad(hull)
    }

    /// Andrew's monotone chain. `cross <= 0` drops collinear points so a digital square reduces to
    /// its corners.
    func convexHull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = pts.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Greedily remove the vertex forming the smallest-area triangle with its neighbours until four
    /// corners remain.
    func simplifyToQuad(_ hull: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var pts = hull
        while pts.count > 4 {
            var best = 0
            var bestArea = Double.infinity
            for i in 0..<pts.count {
                let a = pts[(i - 1 + pts.count) % pts.count]
                let b = pts[i]
                let c = pts[(i + 1) % pts.count]
                let area = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
                if area < bestArea { bestArea = area; best = i }
            }
            pts.remove(at: best)
        }
        return pts
    }

    /// Sorts four points into clockwise order (y-down pixel space) starting from the top-left-most.
    func canonicalQuad(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let c = pts.reduce(.zero, +) / Double(pts.count)
        let sorted = pts.sorted {
            atan2($0.y - c.y, $0.x - c.x) < atan2($1.y - c.y, $1.x - c.x)
        }
        let start = sorted.enumerated().min {
            ($0.element.y, $0.element.x) < ($1.element.y, $1.element.x)
        }!.offset
        return Array(sorted[start...] + sorted[..<start])
    }

    // MARK: - decode

    /// Samples the 6×6 ArUco grid and matches the dictionary over the four rotations with Hamming
    /// ≤ 1. Returns (id, rotation, hamming); nil when the border is not black, contrast is too low,
    /// or no dictionary entry matches.
    func decodeID(of quad: [SIMD2<Double>], in gray: GrayBuffer) -> (id: Int, rotation: Int, hamming: Int)? {
        let h = homography(fromUnitSquareTo: quad)
        var cells = [Double](repeating: 0, count: 36)
        for i in 0..<6 {
            for j in 0..<6 {
                let p = h.applying((Double(j) + 0.5) / 6, (Double(i) + 0.5) / 6)
                cells[i * 6 + j] = gray.sample(p.x, p.y)
            }
        }

        guard let maxCell = cells.max(), let minCell = cells.min() else { return nil }
        let threshold = (maxCell + minCell) / 2

        for i in 0..<6 {
            for j in 0..<6 where i == 0 || i == 5 || j == 0 || j == 5 {
                if cells[i * 6 + j] >= threshold { return nil }
            }
        }
        var borderSum = 0.0, innerSum = 0.0
        for i in 0..<6 {
            for j in 0..<6 {
                if i == 0 || i == 5 || j == 0 || j == 5 { borderSum += cells[i * 6 + j] }
                else { innerSum += cells[i * 6 + j] }
            }
        }
        if innerSum / 16 - borderSum / 20 < 30 { return nil }

        var data = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 4)
        for i in 1..<5 {
            for j in 1..<5 {
                data[i - 1][j - 1] = cells[i * 6 + j] >= threshold
            }
        }

        var best: (id: Int, rotation: Int, hamming: Int)?
        for (id, pattern) in ArucoDictionary.markers {
            for rotation in 0..<4 {
                let hamming = hammingDistance(rotate(data, times: rotation), pattern)
                if hamming <= 1 {
                    if best == nil || hamming < best!.hamming {
                        best = (id, rotation, hamming)
                    } else if hamming == best!.hamming {
                        return nil                              // ambiguous — reject
                    }
                }
            }
        }
        return best
    }

    /// Rotates the 4×4 bit grid `times`×90° counterclockwise.
    func rotate(_ g: [[Bool]], times: Int) -> [[Bool]] {
        var out = [[Bool]](repeating: [Bool](repeating: false, count: 4), count: 4)
        for i in 0..<4 {
            for j in 0..<4 {
                switch times {
                case 0: out[i][j] = g[i][j]
                case 1: out[i][j] = g[j][3 - i]
                case 2: out[i][j] = g[3 - i][3 - j]
                default: out[i][j] = g[3 - j][i]
                }
            }
        }
        return out
    }

    func hammingDistance(_ a: [[Bool]], _ b: [[Bool]]) -> Int {
        var d = 0
        for i in 0..<4 {
            for j in 0..<4 where a[i][j] != b[i][j] { d += 1 }
        }
        return d
    }

    // MARK: - sub-pixel corner refinement

    /// Refines each quad corner: the two adjacent edges are localized to sub-pixel by gradient
    /// profiles near that corner, line-fitted, and intersected.
    func refineCorners(of quad: [SIMD2<Double>], in gray: GrayBuffer) -> [SIMD2<Double>] {
        let center = quad.reduce(.zero, +) / 4
        return (0..<4).map { k in
            let a = quad[k]
            let b = quad[(k + 1) % 4]
            let d = quad[(k + 3) % 4]
            guard let l1 = edgeLine(from: a, to: b, awayFrom: center, in: gray),
                  let l2 = edgeLine(from: a, to: d, awayFrom: center, in: gray),
                  let corner = intersect(l1, l2) else { return a }
            return corner
        }
    }

    /// Fits a line to the black→white step along segment `a…b` (dark inside, bright paper outside).
    func edgeLine(from a: SIMD2<Double>, to b: SIMD2<Double>, awayFrom center: SIMD2<Double>,
                  in gray: GrayBuffer) -> (normal: SIMD2<Double>, offset: Double)? {
        let dir = simd_normalize(b - a)
        var normal = SIMD2<Double>(dir.y, -dir.x)
        let mid = (a + b) / 2
        if simd_dot(normal, mid - center) < 0 { normal = -normal }   // point away from the marker

        let edgeLen = simd_length(b - a)
        let halfWindow = min(4.0, 0.4 * edgeLen)
        let step = 0.25
        let stepCount = Int((halfWindow * 2) / step)

        var points: [SIMD2<Double>] = []
        for m in 0..<7 {
            let t = 0.25 + 0.5 * Double(m) / 6            // 25%–75% along the edge
            let base = a + (b - a) * t
            func value(_ o: Double) -> Double {
                gray.sample((base + normal * o).x, (base + normal * o).y)
            }
            var bestGrad = -Double.infinity
            var bestIndex = 0
            for k in 0..<stepCount {
                let o = -halfWindow + step * Double(k)
                let g = value(o + step) - value(o)
                if g > bestGrad { bestGrad = g; bestIndex = k }
            }
            guard bestGrad > 0 else { continue }
            var bestOffset = -halfWindow + step * Double(bestIndex)
            if bestIndex > 0 && bestIndex < stepCount - 1 {
                let gm = value(bestOffset - step) - value(bestOffset - 2 * step)
                let g0 = value(bestOffset + step) - value(bestOffset)
                let gp = value(bestOffset + 2 * step) - value(bestOffset + step)
                let denom = gm - 2 * g0 + gp
                if abs(denom) > 1e-12 {
                    bestOffset += step / 2 * (gm - gp) / denom
                }
            }
            points.append(base + normal * bestOffset)
        }
        guard points.count >= 4 else { return nil }

        let mean = points.reduce(.zero, +) / Double(points.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let trace = sxx + syy
        let disc = sqrt(max(0, (sxx - syy) * (sxx - syy) + 4 * sxy * sxy))
        guard disc > 1e-12 else { return nil }
        let lambdaSmall = (trace - disc) / 2
        let nx = sxy
        let ny = lambdaSmall - sxx
        let len = (nx * nx + ny * ny).squareRoot()
        guard len > 1e-12 else { return nil }
        let n = SIMD2<Double>(nx / len, ny / len)
        return (n, simd_dot(n, mean))
    }

    func intersect(_ l1: (normal: SIMD2<Double>, offset: Double),
                   _ l2: (normal: SIMD2<Double>, offset: Double)) -> SIMD2<Double>? {
        let det = l1.normal.x * l2.normal.y - l1.normal.y * l2.normal.x
        guard abs(det) > 1e-9 else { return nil }
        let x = (l1.offset * l2.normal.y - l2.offset * l1.normal.y) / det
        let y = (l1.normal.x * l2.offset - l2.normal.x * l1.offset) / det
        return SIMD2<Double>(x, y)
    }

    // MARK: - assemble

    /// Decode one candidate quad: bit decode, sub-pixel corner refinement, contract corner order
    /// (printed top-left first) and top-left-origin normalization.
    func decodeAndRefine(_ quad: [SIMD2<Double>], in gray: GrayBuffer) -> MarkerObservation? {
        var q = quad
        var decoded = decodeID(of: q, in: gray)
        if decoded == nil {
            q = refineCorners(of: q, in: gray)
            decoded = decodeID(of: q, in: gray)
        }
        guard let (id, rotation, hamming) = decoded else { return nil }

        let corners = refineCorners(of: q, in: gray)
        let ordered = (0..<4).map { corners[($0 + rotation) % 4] }
        let normalized = ordered.map {
            SIMD2<Float>(Float(($0.x + 0.5) / Double(gray.width)),
                         Float(($0.y + 0.5) / Double(gray.height)))
        }
        return MarkerObservation(id: id, corners: normalized, hammingDistance: hamming)
    }

    /// Homography mapping the unit square (0,0),(1,0),(1,1),(0,1) onto the quad.
    func homography(fromUnitSquareTo quad: [SIMD2<Double>]) -> Homography2D {
        Homography2D(from: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], to: quad)
    }
}

// MARK: - GrayBuffer

/// 8-bit gray snapshot of a CGImage with bilinear sampling (clamped at borders).
struct GrayBuffer {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    init(_ image: CGImage) throws {
        let w = image.width
        let h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw MarkerDetectorError.grayBuffer }
        width = w
        height = h
        pixels = buffer
    }

    init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    /// Box-filter downsample by an integer factor.
    func downsampled(factor: Int) -> GrayBuffer {
        let w = width / factor, h = height / factor
        var out = [UInt8](repeating: 0, count: w * h)
        let f2 = factor * factor
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                let sx = x * factor, sy = y * factor
                for dy in 0..<factor {
                    let row = (sy + dy) * width
                    for dx in 0..<factor {
                        sum += Int(pixels[row + sx + dx])
                    }
                }
                out[y * w + x] = UInt8(sum / f2)
            }
        }
        return GrayBuffer(pixels: out, width: w, height: h)
    }

    func sample(_ x: Double, _ y: Double) -> Double {
        let cx = min(max(x, 0), Double(width - 1))
        let cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        let v00 = Double(pixels[y0 * width + x0])
        let v10 = Double(pixels[y0 * width + x1])
        let v01 = Double(pixels[y1 * width + x0])
        let v11 = Double(pixels[y1 * width + x1])
        return v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy)
             + v01 * (1 - fx) * fy + v11 * fx * fy
    }
}

private enum MarkerDetectorError: Error {
    case grayBuffer
}

// MARK: - Homography

/// Direct linear transform homography between two quadrilaterals, applied as `h · p / (h₃·p)`.
/// Destination coordinates are normalized (centroid + mean radius) before the DLT for conditioning;
/// the stored transform undoes that normalization.
struct Homography2D {
    let h: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
    private let center: SIMD2<Double>
    private let scale: Double

    init(from src: [SIMD2<Double>], to dst: [SIMD2<Double>]) {
        let c = dst.reduce(.zero, +) / Double(dst.count)
        var s = 0.0
        for p in dst { s += simd_length(p - c) }
        s /= Double(dst.count)

        let norm = dst.map { ($0 - c) / s }
        var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (src[i].x, src[i].y)
            let (u, v) = (norm[i].x, norm[i].y)
            A[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, -u]
            A[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, -v]
        }

        var M = A
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(M[r][col]) > abs(M[pivot][col]) { pivot = r }
            guard abs(M[pivot][col]) > 1e-12 else { continue }
            M.swapAt(col, pivot)
            for r in (col + 1)..<8 {
                let f = M[r][col] / M[col][col]
                for cc in col..<9 { M[r][cc] -= f * M[col][cc] }
            }
        }
        var hh = [Double](repeating: 0, count: 9)
        hh[8] = 1
        var i = 7
        while i >= 0 {
            var sum = M[i][8]
            for j in (i + 1)..<8 { sum += M[i][j] * hh[j] }
            hh[i] = abs(M[i][i]) > 1e-12 ? -sum / M[i][i] : 0
            i -= 1
        }
        var normSq = 0.0
        for v in hh { normSq += v * v }
        let nrm = normSq.squareRoot()
        if nrm > 1e-12 {
            for idx in 0..<9 { hh[idx] /= nrm }
        } else {
            hh = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }

        h = (SIMD3(hh[0], hh[1], hh[2]),
             SIMD3(hh[3], hh[4], hh[5]),
             SIMD3(hh[6], hh[7], hh[8]))
        center = c
        scale = s
    }

    func applying(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let p = SIMD3<Double>(x, y, 1)
        let w = simd_dot(h.2, p)
        let hn = SIMD2(simd_dot(h.0, p) / w, simd_dot(h.1, p) / w)
        return hn * scale + center
    }
}
