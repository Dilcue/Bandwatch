import Testing
import Foundation
@testable import BandwatchCore

private func sine(freq: Double, count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
}

private func rms(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return 0 }
    let sum = x.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(x.count)).squareRoot()
}

/// Discards filter settling time before measuring.
private func steadyState(_ x: [Float]) -> [Float] {
    Array(x.dropFirst(x.count / 2))
}

@Test func testPassbandToneSurvives() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let f = BandFilter(band: band, sampleRate: 44100)
    let input = sine(freq: 60, count: 44100, sampleRate: 44100)
    let output = f.process(input)
    let ratio = rms(steadyState(output)) / rms(steadyState(input))
    // Center of passband should pass with little loss.
    #expect(ratio > 0.7)
}

@Test func testFarAboveBandIsStronglyAttenuated() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let f = BandFilter(band: band, sampleRate: 44100)
    let input = sine(freq: 5000, count: 44100, sampleRate: 44100)
    let output = f.process(input)
    let ratio = rms(steadyState(output)) / rms(steadyState(input))
    // Two decades above the band: expect well over 40 dB down.
    #expect(ratio < 0.01)
}

@Test func testFarBelowBandIsStronglyAttenuated() throws {
    let band = try #require(FrequencyBand(lowHz: 500, highHz: 1000))
    let f = BandFilter(band: band, sampleRate: 44100)
    let input = sine(freq: 20, count: 44100, sampleRate: 44100)
    let output = f.process(input)
    let ratio = rms(steadyState(output)) / rms(steadyState(input))
    #expect(ratio < 0.01)
}

@Test func testOutputLengthMatchesInput() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let f = BandFilter(band: band, sampleRate: 44100)
    let output = f.process(sine(freq: 60, count: 1024, sampleRate: 44100))
    #expect(output.count == 1024)
}

@Test func testStatePersistsAcrossCallsWithoutDiscontinuity() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let whole = BandFilter(band: band, sampleRate: 44100)
    let split = BandFilter(band: band, sampleRate: 44100)

    let input = sine(freq: 60, count: 4096, sampleRate: 44100)
    let wholeOut = whole.process(input)
    let a = split.process(Array(input[0..<2048]))
    let b = split.process(Array(input[2048..<4096]))
    let splitOut = a + b

    // Processing in two chunks must equal processing in one.
    for i in 0..<wholeOut.count {
        #expect(abs(wholeOut[i] - splitOut[i]) < 0.0001)
    }
}

@Test func testResetClearsState() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let f = BandFilter(band: band, sampleRate: 44100)
    _ = f.process(sine(freq: 60, count: 4096, sampleRate: 44100))
    f.reset()
    let afterReset = f.process([Float](repeating: 0, count: 128))
    #expect(afterReset.allSatisfy { abs($0) < 0.0001 })
}

@Test func testSilenceInSilenceOut() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let f = BandFilter(band: band, sampleRate: 44100)
    let output = f.process([Float](repeating: 0, count: 1024))
    #expect(output.allSatisfy { $0 == 0 })
}

/// Measures steady-state gain in dB of a filter at a given frequency, relative
/// to the input tone's own RMS (i.e. absolute gain of the filter at that tone).
private func gainDb(_ filter: BandFilter, freq: Double, sampleRate: Double, count: Int = 44100) -> Double {
    let input = sine(freq: freq, count: count, sampleRate: sampleRate)
    let output = filter.process(input)
    let ratio = rms(steadyState(output)) / rms(steadyState(input))
    return 20 * log10(ratio)
}

@Test func testPassbandEdgesLandAtRequestedFrequencies() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let sampleRate = 44100.0

    let centerGain = gainDb(BandFilter(band: band, sampleRate: sampleRate), freq: band.centerHz, sampleRate: sampleRate)
    let lowGain = gainDb(BandFilter(band: band, sampleRate: sampleRate), freq: 40, sampleRate: sampleRate)
    let highGain = gainDb(BandFilter(band: band, sampleRate: sampleRate), freq: 80, sampleRate: sampleRate)

    // The requested band edges should sit at -3 dB relative to the center, within ~1 dB.
    #expect(abs((centerGain - lowGain) - 3.0) < 1.0)
    #expect(abs((centerGain - highGain) - 3.0) < 1.0)
}

@Test func testUnityGainAtCenter() throws {
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let sampleRate = 44100.0
    let f = BandFilter(band: band, sampleRate: sampleRate)
    let centerGain = gainDb(f, freq: band.centerHz, sampleRate: sampleRate)
    // Gain at the geometric center should be approximately unity (0 dB).
    #expect(abs(centerGain) < 0.5)
}

@Test func test45HzWithinRequestedBandIsNotOverAttenuated() throws {
    // This is the concrete user-facing regression: a user sets 40-80 Hz to
    // capture a 45 Hz thump. With the backwards sqrt(2) correction factor,
    // the cascade narrowed so much that 45 Hz was attenuated well below the
    // requested -3dB edge, silently cutting the target frequency out of the
    // user's own recorded evidence.
    let band = try #require(FrequencyBand(lowHz: 40, highHz: 80))
    let sampleRate = 44100.0

    let centerGain = gainDb(BandFilter(band: band, sampleRate: sampleRate), freq: band.centerHz, sampleRate: sampleRate)
    let gain45 = gainDb(BandFilter(band: band, sampleRate: sampleRate), freq: 45, sampleRate: sampleRate)

    #expect((centerGain - gain45) < 3.0)
}
