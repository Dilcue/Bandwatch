import Foundation

/// Direct Form II transposed biquad coefficients, normalized so a0 == 1.
struct BiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    /// Bandpass section (constant 0 dB peak gain), per the RBJ audio EQ cookbook.
    static func bandpass(centerHz: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let omega = 2.0 * Double.pi * centerHz / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: alpha / a0,
            b1: 0.0,
            b2: -alpha / a0,
            a1: (-2.0 * cosOmega) / a0,
            a2: (1.0 - alpha) / a0
        )
    }
}

/// Single biquad section. Stateful across calls by design.
final class Biquad {
    private let c: BiquadCoefficients
    private var z1 = 0.0
    private var z2 = 0.0

    init(coefficients: BiquadCoefficients) {
        self.c = coefficients
    }

    /// Direct Form II transposed — good numerical behaviour at audio precision.
    func process(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    func reset() {
        z1 = 0
        z2 = 0
    }
}
