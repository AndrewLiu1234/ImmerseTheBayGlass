import Foundation

/// 1€ filter (Casiez, Roussel & Vogel, CHI 2012) for one 2-D landmark: a low-pass whose cutoff rises with speed, so
/// slow motion is smoothed (no jitter) and fast motion is followed closely (no lag). Defaults are tuned for 30 fps
/// normalized landmarks: a step reaches ~90 % within half a second (pinned by OneEuroFilterTests).
struct OneEuroFilter {
    let minCutoff: Double
    let beta: Double
    let derivativeCutoff: Double

    private var lastValue: SIMD2<Double>?
    private var lastDerivative = SIMD2<Double>(0, 0)
    private var lastTimestamp: TimeInterval = 0

    init(minCutoff: Double = 1.0, beta: Double = 0.05, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Timestamps are monotonic seconds. The first sample initializes the state and passes through untouched; a
    /// non-increasing timestamp returns the previous output unchanged (no division by zero).
    mutating func filter(_ value: SIMD2<Float>, timestamp: TimeInterval) -> SIMD2<Float> {
        let x = SIMD2<Double>(Double(value.x), Double(value.y))
        guard let prev = lastValue else {
            lastValue = x
            lastTimestamp = timestamp
            return value
        }
        let dt = timestamp - lastTimestamp
        guard dt > 0 else { return SIMD2<Float>(Float(prev.x), Float(prev.y)) }

        let rawDerivative = (x - prev) / dt
        let dHat = lastDerivative + Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - lastDerivative)
        let speed = (dHat * dHat).sum().squareRoot()
        let cutoff = minCutoff + beta * speed
        let xHat = prev + Self.alpha(cutoff: cutoff, dt: dt) * (x - prev)

        lastValue = xHat
        lastDerivative = dHat
        lastTimestamp = timestamp
        return SIMD2<Float>(Float(xHat.x), Float(xHat.y))
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

/// 1€ filter for a 3-D joint (metres): (x, y) and z each go through a 2-D filter. Speed is estimated per part,
/// which is fine for hands — a fast move in depth still opens up the z filter.
struct OneEuroFilter3 {
    private var xy: OneEuroFilter
    private var z: OneEuroFilter

    init(minCutoff: Double = 1.0, beta: Double = 0.05, derivativeCutoff: Double = 1.0) {
        xy = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        z = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    mutating func filter(_ p: SIMD3<Double>, timestamp: TimeInterval) -> SIMD3<Double> {
        let a = xy.filter(SIMD2(Float(p.x), Float(p.y)), timestamp: timestamp)
        let b = z.filter(SIMD2(Float(p.z), 0), timestamp: timestamp)
        return SIMD3(Double(a.x), Double(a.y), Double(b.x))
    }
}
