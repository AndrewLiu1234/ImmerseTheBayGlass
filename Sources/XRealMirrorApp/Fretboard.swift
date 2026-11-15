import Foundation
import simd

/// The guitar's playing surface in the guitar frame (fretboard spec): origin = nut centre on the fretboard surface,
/// +x along the strings toward the bridge, +y across the neck toward the treble (high-E) side, +z out of the fretboard.
/// Metres. Pure geometry; where the guitar is in the world comes from the marker pose (later tasks).
struct Fretboard: Sendable {
    struct Spec: Codable, Equatable, Sendable {
        var name: String
        var scaleLength: Double            // nut → saddle (uncompensated)
        var fretCount: Int
        var widthAtNut: Double
        var widthAt12th: Double
        var stringSpreadAtNut: Double      // low-E centre → high-E centre
        var stringSpreadAtSaddle: Double
        var stringHeightAtNut: Double      // string above the fretboard surface
        var stringHeightAt12th: Double
        var notes: String

        /// Yamaha F600. Scale 634 mm and nut 43 mm: two retailer spec listings agree (one guide's 650 mm is an
        /// outlier). The rest are Person 1's guesses (standard acoustic, not tape-measured — Sun 02:48); must match
        /// tools/guitar/f600.json (FretboardTests checks).
        static let yamahaF600 = Spec(
            name: "Yamaha F600", scaleLength: 0.634, fretCount: 20, widthAtNut: 0.043, widthAt12th: 0.052,
            stringSpreadAtNut: 0.036, stringSpreadAtSaddle: 0.055, stringHeightAtNut: 0.0006, stringHeightAt12th: 0.0026,
            notes: "Person 1 GUESSES (not tape-measured): scale 634 + nut 43 from retailer specs; width@12 ~52, nut spread ~36, saddle spread ~55 (standard acoustic), action nut 0.6 / 12th 2.6. Refine on a live setup-still if fret/string lines look off.")
    }

    struct GuitarString: Sendable {
        var name: String                   // "E" (6th, low) … "e" (1st, high)
        var nut: SIMD3<Double>
        var saddle: SIMD3<Double>
        let heightAt12th: Double
        let scaleLength: Double

        /// Point on the string at distance x along the neck; height rises linearly from nut to 12th and beyond.
        func point(atX x: Double) -> SIMD3<Double> {
            let f = x / scaleLength
            let y = nut.y + (saddle.y - nut.y) * f
            let z = nut.z + (heightAt12th - nut.z) * (x / (scaleLength / 2))
            return SIMD3(x, y, z)
        }
    }

    let spec: Spec
    let strings: [GuitarString]            // index 0 = low E (bass, -y) … 5 = high E (treble, +y)

    init(spec: Spec) {
        self.spec = spec
        let names = ["E", "A", "D", "G", "B", "e"]
        strings = (0..<6).map { i in
            let f = Double(i) / 5 - 0.5
            return GuitarString(name: names[i],
                                nut: SIMD3(0, f * spec.stringSpreadAtNut, spec.stringHeightAtNut),
                                saddle: SIMD3(spec.scaleLength, f * spec.stringSpreadAtSaddle,
                                              spec.stringHeightAtNut + 2 * (spec.stringHeightAt12th - spec.stringHeightAtNut)),
                                heightAt12th: spec.stringHeightAt12th, scaleLength: spec.scaleLength)
        }
    }

    /// Distance from the nut to fret k (k = 0 is the nut), equal temperament.
    func fretX(_ k: Int) -> Double { spec.scaleLength * (1 - pow(2, -Double(k) / 12)) }

    /// Half the fretboard width at x (linear taper through the nut and 12th-fret widths).
    func halfWidth(atX x: Double) -> Double {
        (spec.widthAtNut + (spec.widthAt12th - spec.widthAtNut) * x / (spec.scaleLength / 2)) / 2
    }

    /// Fret k as a segment on the fretboard surface, bass edge first.
    func fretLine(_ k: Int) -> (SIMD3<Double>, SIMD3<Double>) {
        let x = fretX(k), h = halfWidth(atX: x)
        return (SIMD3(x, -h, 0), SIMD3(x, h, 0))
    }

    /// The fretboard outline (nut → last fret) as a closed polygon on its surface: bass edge, then treble edge back.
    var outline: [SIMD3<Double>] {
        let end = fretX(spec.fretCount) + 0.01
        return [SIMD3(0, -halfWidth(atX: 0), 0), SIMD3(end, -halfWidth(atX: end), 0),
                SIMD3(end, halfWidth(atX: end), 0), SIMD3(0, halfWidth(atX: 0), 0)]
    }
}
