import Foundation

/// One-euro filter (Casiez et al. 2012): an adaptive low-pass filter that removes jitter at low speeds while
/// keeping lag small at high speeds. Speeds are expected in normalised units (fractions of the display per second)
/// so `beta` is resolution independent.
struct OneEuroFilter: Sendable {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    private var previous: SIMD2<Double>?
    private var previousDerivative: SIMD2<Double> = .zero

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * max(cutoff, 1e-6))
        return 1 / (1 + tau / max(dt, 1e-6))
    }

    /// `speedScale` converts position units to the normalised speed used for the adaptive cutoff.
    mutating func filter(_ value: SIMD2<Double>, dt: Double, speedScale: Double = 1) -> SIMD2<Double> {
        guard let prev = previous else {
            previous = value
            previousDerivative = .zero
            return value
        }
        let derivative = (value - prev) / max(dt, 1e-6)
        let aD = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = previousDerivative + (derivative - previousDerivative) * aD
        previousDerivative = smoothedDerivative
        let speed = simd_length(smoothedDerivative) * speedScale
        let cutoff = minCutoff + beta * speed
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let result = prev + (value - prev) * a
        previous = result
        return result
    }
}
