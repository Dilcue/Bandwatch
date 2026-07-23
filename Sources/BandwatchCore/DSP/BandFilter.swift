import Foundation

/// 4-pole cascaded bandpass built from two identical biquad sections, with
/// section Q bandwidth-corrected so the cascade's -3 dB points land at the
/// requested band edges. Unity gain at the geometric centre.
///
/// This is NOT a true Butterworth bandpass — a true Butterworth bandpass
/// requires sections with distinct centre frequencies and Q values derived
/// from a lowpass-to-bandpass transform. Here both sections share the same
/// centre frequency and Q; the only correction applied is for the bandwidth
/// narrowing that cascading introduces (see `cascadeBandwidthCorrection`
/// below). That correction is sufficient for this application's needs.
///
/// Stateful across calls: filter memory persists between buffers, so processing
/// a signal in chunks yields the same result as processing it whole. Call
/// `reset()` only when changing bands.
public final class BandFilter {
    public let band: FrequencyBand
    public let sampleRate: Double

    private let sections: [Biquad]

    /// Number of identical 2-pole sections cascaded together.
    private static let sectionCount = 2

    // Cascading N identical 2-pole sections narrows the combined -3 dB bandwidth by
    // sqrt(2^(1/N) - 1). Scale each section's Q down by that factor so the CASCADE's
    // -3 dB points land on the requested band edges.
    //
    // Verified for a 40-80 Hz request at 44.1 kHz: this yields -3 dB at 40.2 .. 80.0 Hz.
    // Using sqrt(2) instead (the previous value) gave 48.2 .. 66.2 Hz — a passband
    // 2.2x too narrow, which would silently cut the user's target frequency out of
    // their own recorded evidence.
    private static let cascadeBandwidthCorrection =
        (pow(2.0, 1.0 / Double(sectionCount)) - 1).squareRoot()

    public init(band: FrequencyBand, sampleRate: Double) {
        self.band = band
        self.sampleRate = sampleRate

        let center = band.centerHz
        let bandwidth = band.highHz - band.lowHz
        // Q of the overall requested filter response.
        let overallQ = max(center / max(bandwidth, 0.0001), 0.1)
        // Per-section Q, corrected so the cascade (not a single section) hits
        // the requested -3 dB edges.
        let sectionQ = overallQ * Self.cascadeBandwidthCorrection

        self.sections = (0..<Self.sectionCount).map { _ in
            Biquad(coefficients: .bandpass(centerHz: center, q: sectionQ, sampleRate: sampleRate))
        }
    }

    public func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            var sample = Double(input[i])
            for section in sections {
                sample = section.process(sample)
            }
            output[i] = Float(sample)
        }
        return output
    }

    public func reset() {
        for section in sections { section.reset() }
    }
}
