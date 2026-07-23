import Testing
import Foundation
@testable import BandwatchCore

private func sine(freq: Double, amplitude: Float = 1.0, count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
}

@Test func testSilenceReturnsFloor() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    let mags = a.analyze([Float](repeating: 0, count: 8192))
    let level = meter.level(magnitudes: mags, band: .bassSubwoofer)
    #expect(level == BandLevelMeter.silenceFloorDBFS)
}

@Test func testInBandToneProducesHighLevel() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    let mags = a.analyze(sine(freq: 50, count: 8192, sampleRate: 44100))
    let level = meter.level(magnitudes: mags, band: .bassSubwoofer)
    #expect(level > -20.0)
}

@Test func testOutOfBandToneProducesLowLevel() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    // 5 kHz tone measured in the 20-120 Hz band should be near the floor.
    let mags = a.analyze(sine(freq: 5000, count: 8192, sampleRate: 44100))
    let level = meter.level(magnitudes: mags, band: .bassSubwoofer)
    #expect(level < -40.0)
}

@Test func testHalvingAmplitudeDropsLevelBySixDB() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    let loud = meter.level(
        magnitudes: a.analyze(sine(freq: 50, amplitude: 1.0, count: 8192, sampleRate: 44100)),
        band: .bassSubwoofer)
    let quiet = meter.level(
        magnitudes: a.analyze(sine(freq: 50, amplitude: 0.5, count: 8192, sampleRate: 44100)),
        band: .bassSubwoofer)
    #expect(abs((loud - quiet) - 6.02) < 0.5)
}

@Test func testLevelIsFiniteForAllInputs() throws {
    // Covers several genuinely distinct degenerate input shapes, not just
    // silence (that case is already covered by testSilenceReturnsFloor):
    // NaN contamination in the magnitudes array, an empty magnitudes array,
    // and a band entirely above Nyquist. All must return a finite level
    // (the silence floor), never NaN or infinity propagating to the UI.
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)

    var nanMags = a.analyze([Float](repeating: 0, count: 8192))
    nanMags[nanMags.count / 2] = .nan
    #expect(meter.level(magnitudes: nanMags, band: .bassSubwoofer).isFinite)

    #expect(meter.level(magnitudes: [], band: .bassSubwoofer).isFinite)

    let aboveNyquist = try #require(FrequencyBand(lowHz: 23000, highHz: 24000))
    let mags = a.analyze([Float](repeating: 0, count: 8192))
    #expect(meter.level(magnitudes: mags, band: aboveNyquist).isFinite)
}

// MARK: - Regression test for Finding 1 (band-width dependence)

/// Regression test for the bug where in-band level was computed as mean-square
/// across bins (sumSquares / binCount) instead of true in-band power. That made
/// the same physical tone read many dB quieter purely because the measurement
/// band was wider — e.g. a full-scale 48.45 Hz tone read -5.23 dBFS in a 40-60 Hz
/// band but several dB lower in a 20-2000 Hz band. Since the user picks the band
/// by dragging on a spectrum chart, that meant their threshold silently changed
/// meaning every time they retuned the band width.
///
/// If anyone reintroduces `/ Double(highBin - lowBin + 1)`, this test fails
/// loudly: the 20-2000 Hz band (far more bins) would read many dB lower than
/// the 40-60 Hz band (5 bins), far outside the 0.5 dB tolerance below.
@Test func testLevelIsBandWidthIndependent() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    // Bin 9 is an exact bin centre (freq = 9 * binWidthHz ~= 48.45 Hz) that falls
    // inside every band below.
    let freq = Double(9) * a.binWidthHz
    let mags = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100))

    let bands = [
        try #require(FrequencyBand(lowHz: 40, highHz: 60)),
        try #require(FrequencyBand(lowHz: 20, highHz: 120)),
        try #require(FrequencyBand(lowHz: 20, highHz: 500)),
        try #require(FrequencyBand(lowHz: 20, highHz: 2000)),
    ]
    let levels = bands.map { meter.level(magnitudes: mags, band: $0) }
    let reference = levels[0]
    for level in levels {
        #expect(abs(level - reference) < 0.5)
    }
}

// MARK: - Calibration tests
//
// These two tests pin the dBFS convention: a full-scale tone at an exact bin
// centre must read ~0 dBFS. If the normalization constant (the Hann noise power
// bandwidth divisor) is ever consciously changed, these tests must be updated
// to match the new convention — do not adjust the tolerance to make them pass
// without understanding why the value moved.

@Test func testFullScaleSineAtBinCentreReadsZeroDBFS() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    // Use an exact bin centre frequency, not a round number like 50 Hz: a
    // non-centre frequency suffers scalloping loss and would not read 0 dBFS.
    let freq = Double(9) * a.binWidthHz
    let mags = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100))
    let band = try #require(FrequencyBand(lowHz: 20, highHz: 120))
    let level = meter.level(magnitudes: mags, band: band)
    #expect(abs(level - 0.0) < 0.2)
}

@Test func testBandAboveNyquistReturnsSilenceFloor() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let meter = BandLevelMeter(analyzer: a)
    // Nyquist is 22050 Hz for this sample rate; this band is entirely above it.
    let band = try #require(FrequencyBand(lowHz: 23000, highHz: 24000))
    let mags = a.analyze(sine(freq: 23500, count: 8192, sampleRate: 44100))
    let level = meter.level(magnitudes: mags, band: band)
    #expect(level == BandLevelMeter.silenceFloorDBFS)
}
