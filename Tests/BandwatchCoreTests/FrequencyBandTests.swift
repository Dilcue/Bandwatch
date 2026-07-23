import Testing
import Foundation
@testable import BandwatchCore

@Test func testValidBandIsCreated() throws {
    let b = try #require(FrequencyBand(lowHz: 20, highHz: 120))
    #expect(b.lowHz == 20)
    #expect(b.highHz == 120)
}

@Test func testBassBandDoesNotOverlapSpeech() {
    #expect(FrequencyBand.bassSubwoofer.overlapsSpeechRange == false)   // 20–120 Hz
}

@Test func testBeepingAndWhineBandsOverlapSpeech() {
    #expect(FrequencyBand.beeping.overlapsSpeechRange)        // 1000–4000 Hz
    #expect(FrequencyBand.applianceWhine.overlapsSpeechRange) // 2000–8000 Hz
}

@Test func testSpeechOverlapBoundaries() throws {
    // Touching the low boundary exactly does not overlap (high == 300).
    #expect(try #require(FrequencyBand(lowHz: 100, highHz: 300)).overlapsSpeechRange == false)
    // Dipping just into the speech band overlaps.
    #expect(try #require(FrequencyBand(lowHz: 100, highHz: 320)).overlapsSpeechRange)
    // A band starting exactly at the high boundary does not overlap (low == 3400).
    #expect(try #require(FrequencyBand(lowHz: 3400, highHz: 5000)).overlapsSpeechRange == false)
    // A band ending inside the speech band overlaps.
    #expect(try #require(FrequencyBand(lowHz: 3000, highHz: 5000)).overlapsSpeechRange)
}

@Test func testInvertedBandIsRejected() {
    #expect(FrequencyBand(lowHz: 120, highHz: 20) == nil)
}

@Test func testEqualBoundsRejected() {
    #expect(FrequencyBand(lowHz: 100, highHz: 100) == nil)
}

@Test func testNegativeOrZeroLowRejected() {
    #expect(FrequencyBand(lowHz: -5, highHz: 100) == nil)
    #expect(FrequencyBand(lowHz: 0, highHz: 100) == nil)
}

@Test func testCenterIsGeometricMean() throws {
    let b = try #require(FrequencyBand(lowHz: 100, highHz: 400))
    // Geometric mean = 200, not arithmetic mean 250.
    #expect(abs(b.centerHz - 200.0) < 0.001)
}

@Test func testContains() throws {
    let b = try #require(FrequencyBand(lowHz: 20, highHz: 120))
    #expect(b.contains(50))
    #expect(b.contains(20))
    #expect(b.contains(120))
    #expect(!b.contains(19.9))
    #expect(!b.contains(120.1))
}

@Test func testPresets() {
    #expect(FrequencyBand.bassSubwoofer.lowHz == 20)
    #expect(FrequencyBand.bassSubwoofer.highHz == 120)
    #expect(FrequencyBand.applianceWhine.lowHz == 2000)
    #expect(FrequencyBand.beeping.highHz == 4000)
}

@Test func testCodableRoundTrip() throws {
    let b = try #require(FrequencyBand(lowHz: 45, highHz: 65))
    let data = try JSONEncoder().encode(b)
    let decoded = try JSONDecoder().decode(FrequencyBand.self, from: data)
    #expect(decoded == b)
}
