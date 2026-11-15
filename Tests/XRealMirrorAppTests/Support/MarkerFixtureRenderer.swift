import CoreGraphics
import Foundation
import ImageIO
import simd
@testable import XRealMirrorApp

// Test support for the fretboard stage (Person 2 plan, Task 1): renders the three real ArUco markers on a simple
// guitar into BOTH glasses cameras through the calibrated fisheye model, with exact ground truth. Shared read-only
// with Person 1's detector tests via fixtures/markers-synthetic/.
//
// Pixel convention (OpenCV, same as the calibration): pixel (u, v) has its CENTRE at integer (u, v); the image spans
// [-0.5, W-0.5] × [-0.5, H-0.5]. Contract-normalized coordinates (origin top-left, 0...1 over the image) are
// n = (px + 0.5) / size.

/// The printed markers (spec Facts table): 4×4 data bits, rows top→bottom as printed upright, "1" = white.
/// A test-side copy so fixtures don't depend on Person 1's ArucoDictionary; once that lands, a test cross-checks them.
enum TestMarkerPatterns {
    static let bits: [Int: [String]] = [
        7: ["1100", "0100", "1111", "0010"],
        8: ["1111", "1110", "1101", "1010"],
        9: ["1100", "1111", "0101", "0110"],
    ]
    static let ids = [7, 8, 9]
    static let side = 0.060          // black square outer edge, metres
    static let paper = 0.090         // white paper square around it (quiet zone)

    /// 6×6 grid cell (row, col), border included. true = white.
    static func isWhite(id: Int, row: Int, col: Int) -> Bool {
        guard (1...4).contains(row), (1...4).contains(col), let rows = bits[id] else { return false }
        let r = Array(rows[row - 1])
        return r[col - 1] == "1"
    }
}

/// A planar marker's pose: X = center + u*a + v*b with u = printed-right, v = printed-down (metres from the centre);
/// the printed face is the side `face` points to.
struct MarkerPlacement: Codable, Equatable {
    var id: Int
    var center: SIMD3<Double>
    var right: SIMD3<Double>     // printed +x (unit)
    var down: SIMD3<Double>      // printed +y (unit)
    var face: SIMD3<Double> { simd_normalize(simd_cross(down, right)) }   // out of the printed side

    /// Black-square corners in contract order: printed top-left, top-right, bottom-right, bottom-left.
    func corners(side: Double = TestMarkerPatterns.side) -> [SIMD3<Double>] {
        let h = side / 2
        return [center - h * right - h * down, center + h * right - h * down,
                center + h * right + h * down, center - h * right + h * down]
    }

    func transformed(_ r: simd_double3x3, _ t: SIMD3<Double>) -> MarkerPlacement {
        MarkerPlacement(id: id, center: r * center + t, right: r * right, down: r * down)
    }
}

/// Where the markers sit on the guitar for fixtures (an approximation of IMG_3385; the real map comes from the setup
/// capture). Guitar frame = spec: origin nut centre on the fretboard surface, +x to bridge, +y treble, +z out.
enum FixtureGuitar {
    static let fret14 = 0.634 * (1 - pow(2, -14.0 / 12))          // 0.3516 m
    static let headstockAngle = 13.0 * .pi / 180

    static var markers: [MarkerPlacement] {
        let y = SIMD3<Double>(0, 1, 0), x = SIMD3<Double>(1, 0, 0)
        let c = cos(headstockAngle), s = sin(headstockAngle)
        let alongHead = SIMD3<Double>(-c, 0, -s)                    // from the nut out along the headstock (tilted back)
        // Paper sits 0.5 mm proud of the wood it's taped to (coplanar patches would z-fight in the renderer).
        let raw = [
            MarkerPlacement(id: 7, center: SIMD3(fret14, 0.0645, -0.009), right: y, down: x),
            MarkerPlacement(id: 8, center: SIMD3(fret14, -0.0645, -0.009), right: y, down: x),
            MarkerPlacement(id: 9, center: 0.045 * alongHead + SIMD3(0, 0, -0.004), right: y, down: -alongHead),
        ]
        return raw.map { m in var m = m; m.center += 0.0005 * m.face; return m }
    }

    /// Flat patches drawn around the markers: (centre, axis a, axis b, half extents, albedo). Guitar frame.
    static var surfaces: [(c: SIMD3<Double>, a: SIMD3<Double>, b: SIMD3<Double>, ha: Double, hb: Double, albedo: Double)] {
        let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0)
        let c = cos(headstockAngle), s = sin(headstockAngle)
        let alongHead = SIMD3<Double>(-c, 0, -s)
        return [
            (SIMD3(0.19, 0, 0), x, y, 0.19, 0.027, 0.18),                         // rosewood fretboard
            (0.09 * alongHead + SIMD3(0, 0, -0.004), -alongHead, y, 0.09, 0.042, 0.32), // headstock
            (SIMD3(0.58, 0, -0.009), x, y, 0.25, 0.20, 0.55),                     // spruce top
        ]
    }
}

struct FixturePair: Codable {
    struct EyeTruth: Codable {
        var id: Int
        var visible: Bool             // whole black square inside the image and facing this camera
        var incidenceDeg: Double      // angle between the marker face normal and the line of sight
        var cornersPx: [SIMD2<Double>]    // contract order, OpenCV pixel convention
    }
    var index: Int
    var kind: String                  // "frontal" | "playing" | "clutter"
    var guitarRotation: [SIMD3<Double>]?  // columns of R (guitar → left camera), nil for clutter
    var guitarTranslation: SIMD3<Double>?
    var markers: [MarkerPlacement]    // in the LEFT camera frame
    var left: [EyeTruth]
    var right: [EyeTruth]
}

/// Deterministic RNG so fixtures regenerate byte-identically.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &self) }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(0...1), 1e-12), u2 = uniform(0...1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum MarkerFixtureRenderer {
    static let width = 480, height = 640
    static let cal = StereoCalibration.xrealAir2Ultra

    /// Per-eye unit rays for 2×2 supersamples of every pixel (computed once; unproject is the slow part).
    final class RayTable: @unchecked Sendable {   // immutable after init
        let rays: [SIMD3<Double>]
        init(lens: FisheyeLens) {
            var r = [SIMD3<Double>](repeating: .zero, count: MarkerFixtureRenderer.width * MarkerFixtureRenderer.height * 4)
            let offs: [SIMD2<Double>] = [SIMD2(-0.25, -0.25), SIMD2(0.25, -0.25), SIMD2(-0.25, 0.25), SIMD2(0.25, 0.25)]
            for v in 0..<MarkerFixtureRenderer.height {
                for u in 0..<MarkerFixtureRenderer.width {
                    for k in 0..<4 {
                        r[(v * MarkerFixtureRenderer.width + u) * 4 + k] = lens.unproject(pixel: SIMD2(Double(u), Double(v)) + offs[k])
                    }
                }
            }
            rays = r
        }
    }

    private struct Patch {
        var origin: SIMD3<Double>, a: SIMD3<Double>, b: SIMD3<Double>, n: SIMD3<Double>
        var ha: Double, hb: Double
        var albedo: (Double, Double) -> Double?   // (s, t) in metres on the patch → albedo, nil = hole
        var twoSided: Bool
    }

    /// Renders one eye. `markers`/`surfaces` are in THIS eye's camera frame.
    static func renderEye(rays: RayTable, markers: [MarkerPlacement],
                          surfaces: [(c: SIMD3<Double>, a: SIMD3<Double>, b: SIMD3<Double>, ha: Double, hb: Double, albedo: Double)],
                          clutterSeed: UInt64, exposure: Double, noiseSeed: UInt64) -> [UInt8] {
        var patches: [Patch] = []
        for m in markers {
            let cell = TestMarkerPatterns.side / 6, h = TestMarkerPatterns.side / 2
            patches.append(Patch(origin: m.center, a: m.right, b: m.down, n: m.face,
                                 ha: TestMarkerPatterns.paper / 2, hb: TestMarkerPatterns.paper / 2, albedo: { s, t in
                guard abs(s) < h, abs(t) < h else { return 0.88 }              // paper
                let col = min(5, Int((s + h) / cell)), row = min(5, Int((t + h) / cell))
                return TestMarkerPatterns.isWhite(id: m.id, row: row, col: col) ? 0.88 : 0.06
            }, twoSided: false))
        }
        for s in surfaces {
            let n = simd_normalize(simd_cross(s.a, s.b))
            patches.append(Patch(origin: s.c, a: s.a, b: s.b, n: n, ha: s.ha, hb: s.hb, albedo: { _, _ in s.albedo }, twoSided: true))
        }
        // Image-space clutter: a smooth gradient plus a few random grey rectangles (desks, papers, screens).
        var crng = SplitMix64(state: clutterSeed)
        let rects: [(CGRect, Double)] = (0..<9).map { _ in
            let w = crng.uniform(20...160), h = crng.uniform(20...160)
            return (CGRect(x: crng.uniform(0...480), y: crng.uniform(0...640), width: w, height: h), crng.uniform(0.15...0.9))
        }
        var img = [Double](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                var acc = 0.0
                for k in 0..<4 {
                    let d = rays.rays[(v * width + u) * 4 + k]
                    var bestT = Double.infinity, value: Double?
                    for p in patches {
                        let dn = simd_dot(d, p.n)
                        guard abs(dn) > 1e-9 else { continue }
                        if !p.twoSided && dn > 0 { continue }                    // looking at the back of the paper
                        let t = simd_dot(p.origin, p.n) / dn
                        guard t > 0.01, t < bestT else { continue }
                        let q = t * d - p.origin
                        let s = simd_dot(q, p.a), tt = simd_dot(q, p.b)
                        guard abs(s) <= p.ha, abs(tt) <= p.hb, let alb = p.albedo(s, tt) else { continue }
                        bestT = t
                        value = alb * (0.6 + 0.4 * abs(dn))                     // a little shading by incidence
                    }
                    if let value { acc += value } else {
                        var bg = 0.35 + 0.25 * Double(v) / Double(height)
                        let pt = CGPoint(x: u, y: v)
                        for (r, g) in rects where r.contains(pt) { bg = g }
                        acc += bg
                    }
                }
                img[v * width + u] = acc / 4 * exposure
            }
        }
        // Mild optical blur ([1 2 1]/4 separable) + sensor noise.
        var tmp = img
        for v in 0..<height { for u in 1..<(width - 1) { tmp[v * width + u] = (img[v * width + u - 1] + 2 * img[v * width + u] + img[v * width + u + 1]) / 4 } }
        for v in 1..<(height - 1) { for u in 0..<width { img[v * width + u] = (tmp[(v - 1) * width + u] + 2 * tmp[v * width + u] + tmp[(v + 1) * width + u]) / 4 } }
        var nrng = SplitMix64(state: noiseSeed)
        return img.map { UInt8(max(0, min(255, ($0 * 255 + 2.5 * nrng.gaussian()).rounded()))) }
    }

    static func eyeTruth(_ markers: [MarkerPlacement], lens: FisheyeLens, toEye: (SIMD3<Double>) -> SIMD3<Double>,
                         eyeRotation: simd_double3x3) -> [FixturePair.EyeTruth] {
        markers.map { m in
            let cs = m.corners().map(toEye)
            let px = cs.map { lens.project($0) }
            let center = toEye(m.center), face = eyeRotation * m.face
            let cosInc = simd_dot(simd_normalize(-center), face)
            let inside = px.allSatisfy { p in
                guard let p else { return false }
                return p.x >= 0 && p.x <= Double(width - 1) && p.y >= 0 && p.y <= Double(height - 1)
            }
            return FixturePair.EyeTruth(id: m.id, visible: inside && cosInc > 0.1,
                                        incidenceDeg: acos(max(-1, min(1, cosInc))) * 180 / .pi,
                                        cornersPx: px.map { $0 ?? SIMD2(-1, -1) })
        }
    }

    static func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Guitar pose in the left camera frame: `anchor` (a guitar-frame point) lands at `position`, the fretboard
    /// normal (+z_G) becomes `normal`, and +x_G (toward the bridge) is `xHint` projected into the fretboard plane.
    static func pose(anchor: SIMD3<Double>, position: SIMD3<Double>, normal: SIMD3<Double>,
                     xHint: SIMD3<Double>) -> (simd_double3x3, SIMD3<Double>) {
        let z = simd_normalize(normal)
        let x = simd_normalize(xHint - simd_dot(xHint, z) * z)
        let y = simd_cross(z, x)
        let r = simd_double3x3(columns: (x, y, z))
        return (r, position - r * anchor)
    }

    static func rotate(_ v: SIMD3<Double>, axis: SIMD3<Double>, angle: Double) -> SIMD3<Double> {
        simd_quatd(angle: angle, axis: simd_normalize(axis)).act(v)
    }
}
