import Foundation

/// Computes an in-band level in dBFS from FFT magnitudes.
///
/// Levels are relative to digital full scale. They are NOT calibrated sound
/// pressure levels — see the spec's calibration section.
///
/// **This is a tone/amplitude-referenced level, not true RMS.** The
/// normalization divides in-band sum-of-squares by the analysis window's
/// noise power bandwidth (see the comment at `amplitude` below), which is the
/// standard convention for a spectrum-analyzer-style reading: it calibrates
/// the meter so that a full-scale sine sampled at an exact FFT bin centre
/// reads 0.00 dBFS. True RMS of a full-scale sine is -3.01 dBFS (its RMS is
/// amplitude / sqrt(2)), so this convention reads about 3 dB high for tonal
/// signals relative to true RMS. For broadband noise the two conventions
/// coincide — the same expression yields true mean-square power there.
///
/// Net effect: a tonal source (e.g. a narrowband hum or whine) and broadband
/// noise of equal true RMS power will NOT read the same level here — the
/// tone reads ~3 dB higher. This is a defensible, standard analyzer choice,
/// not a bug, but it must be understood before any future SPL calibration:
/// that calibration must be derived using a **tonal** reference source (a
/// pure sine from a calibrator), not pink or white noise. Calibrating against
/// a broadband reference would bake in a ~3 dB error, applied retroactively
/// to the entire historical archive (per the spec's calibration design,
/// calibration is a display-time offset applied to all stored dBFS values).
public struct BandLevelMeter {
    public static let silenceFloorDBFS: Double = -120.0

    private let analyzer: SpectrumAnalyzer

    public init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    public func level(magnitudes: [Float], band: FrequencyBand) -> Double {
        // A band entirely at or above Nyquist is physically meaningless.
        // binIndex(forFrequency:) clamps into range, so without this guard such a
        // band would silently collapse to the top bin and report its magnitude as
        // though it were a valid in-band reading.
        guard band.lowHz < analyzer.sampleRate / 2 else {
            return Self.silenceFloorDBFS
        }

        let lowBin = analyzer.binIndex(forFrequency: band.lowHz)
        let highBin = analyzer.binIndex(forFrequency: band.highHz)
        guard lowBin <= highBin, highBin < magnitudes.count else {
            return Self.silenceFloorDBFS
        }

        // Sum of squared magnitudes across the band -> in-band power.
        var sumSquares = 0.0
        for bin in lowBin...highBin {
            let m = Double(magnitudes[bin])
            sumSquares += m * m
        }

        // Normalize by the analysis window's actual noise power bandwidth, not the number of
        // bins in the band. A full-scale tone's energy spreads across the window's
        // main lobe regardless of band width; dividing by bin count instead would
        // make the reported level depend on how wide the user's chosen band is.
        // The bandwidth is derived from the window's actual coefficients, so it stays
        // correct if the window type ever changes.
        let amplitude = (sumSquares / analyzer.windowNoisePowerBandwidth).squareRoot()
        guard amplitude > 0 else { return Self.silenceFloorDBFS }

        let dbfs = 20.0 * log10(amplitude)
        return max(dbfs, Self.silenceFloorDBFS)
    }
}
