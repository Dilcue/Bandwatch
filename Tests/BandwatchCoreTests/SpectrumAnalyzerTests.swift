import Testing
import Foundation
@testable import BandwatchCore

private func sine(freq: Double, count: Int, sampleRate: Double, amplitude: Float = 1.0) -> [Float] {
    (0..<count).map { i -> Float in
        let phase = 2.0 * .pi * freq * Double(i) / sampleRate
        let sample = sin(phase)
        return amplitude * Float(sample)
    }
}

@Test func testRejectsNonPowerOfTwoFFTSize() {
    #expect(SpectrumAnalyzer(fftSize: 1000, sampleRate: 44100) == nil)
}

@Test func testBinGeometry() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    #expect(a.binCount == 4096)
    #expect(abs(a.binWidthHz - 44100.0 / 8192.0) < 0.0001)
}

@Test func testOneKilohertzSinePeaksAtCorrectBin() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let mags = a.analyze(sine(freq: 1000, count: 8192, sampleRate: 44100))
    let peak = mags.enumerated().max(by: { $0.element < $1.element })!.offset
    let peakHz = a.frequency(ofBin: peak)
    // One bin is ~5.38 Hz; allow two bins of slack for windowing.
    #expect(abs(peakHz - 1000.0) < 11.0)
}

@Test func testFiftyHertzSinePeaksAtCorrectBin() throws {
    // The nuisance-bass case the app actually cares about.
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let mags = a.analyze(sine(freq: 50, count: 8192, sampleRate: 44100))
    let peak = mags.enumerated().max(by: { $0.element < $1.element })!.offset
    #expect(abs(a.frequency(ofBin: peak) - 50.0) < 11.0)
}

@Test func testBinIndexRoundTrips() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let idx = a.binIndex(forFrequency: 1000)
    #expect(abs(a.frequency(ofBin: idx) - 1000.0) < a.binWidthHz)
}

@Test func testBinIndexClampsToValidRange() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    #expect(a.binIndex(forFrequency: -100) == 0)
    #expect(a.binIndex(forFrequency: 999_999) == a.binCount - 1)
}

@Test func testSilenceProducesNearZeroMagnitudes() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let mags = a.analyze([Float](repeating: 0, count: 8192))
    #expect(mags.allSatisfy { $0 < 0.0001 })
}

@Test func testShortInputIsZeroPaddedNotCrashing() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let mags = a.analyze(sine(freq: 1000, count: 1000, sampleRate: 44100))
    #expect(mags.count == 4096)
}

@Test func testLongerThanFFTSizeInputIsTruncatedNotCrashing() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    // Twice fftSize worth of samples; only the first fftSize should be used.
    let mags = a.analyze(sine(freq: 1000, count: 16384, sampleRate: 44100))
    #expect(mags.count == 4096)
    let peak = mags.enumerated().max(by: { $0.element < $1.element })!.offset
    #expect(abs(a.frequency(ofBin: peak) - 1000.0) < 11.0)
}

@Test func testShortInputAfterLoudLongInputIsNotContaminatedByStaleBuffer() throws {
    // Regression test for Finding 1: `input` is a reused scratch buffer, so it
    // must be fully re-zeroed each call. If a previous, longer, loud call left
    // samples in the tail of the buffer, a later short call's zero-padding
    // region would be contaminated by them, and this silence-adjacent check
    // would fail.
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    _ = a.analyze(sine(freq: 1000, count: 8192, sampleRate: 44100))
    let mags = a.analyze([Float](repeating: 0, count: 100))
    #expect(mags.allSatisfy { $0 < 0.0001 })
}

// Convention tests: these pin the normalization convention and verify that
// peak bin magnitude equals the amplitude of a sine at that bin's centre
// frequency. A future change to the scale constant (2/fftSize) must
// consciously update these tests.

@Test func testPeakMagnitudeEqualsAmplitudeAtBinCentre() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let bin = 186
    let freq = Double(bin) * a.binWidthHz
    let mags = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100, amplitude: 1.0))
    let peak = mags[bin]
    #expect(abs(peak - 1.0) < 0.01)
}

@Test func testMagnitudeLinearityAtBinCentre() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let bin = 186
    let freq = Double(bin) * a.binWidthHz

    // Amplitude 0.5 should read as magnitude 0.5
    let mags05 = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100, amplitude: 0.5))
    #expect(abs(mags05[bin] - 0.5) < 0.01)

    // Amplitude 0.25 should read as magnitude 0.25
    let mags025 = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100, amplitude: 0.25))
    #expect(abs(mags025[bin] - 0.25) < 0.01)
}

@Test func testMagnitudeConventionAtDifferentBinCentre() throws {
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    let bin = 400
    let freq = Double(bin) * a.binWidthHz
    let mags = a.analyze(sine(freq: freq, count: 8192, sampleRate: 44100, amplitude: 1.0))
    let peak = mags[bin]
    #expect(abs(peak - 1.0) < 0.01)
}

@Test func testWindowNoisePowerBandwidthForHannWindow() throws {
    // Pins the Hann window's noise power bandwidth at 1.5 bins.
    // This tripwire will fire if the window type ever changes—that's the point.
    // The window choice itself is not constrained; the test just ensures the
    // coupling between SpectrumAnalyzer and any consumers (like BandLevelMeter)
    // is explicit and derived from the actual window, not assumed.
    let a = try #require(SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100))
    #expect(abs(a.windowNoisePowerBandwidth - 1.5) < 0.001)
}
