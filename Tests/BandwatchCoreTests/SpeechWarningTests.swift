import Testing
import Foundation
@testable import BandwatchCore

private func ev(bandLow: Double, bandHigh: Double) -> EventRecord {
    EventRecord(id: 1, startedAt: Date(timeIntervalSince1970: 1_784_000_000), durationSec: 5,
                peakDBFS: -20, meanDBFS: -30, bandLowHz: bandLow, bandHighHz: bandHigh,
                thresholdDBFS: -40, deviceUID: "D", clipPath: "/c.flac")
}

private func report(_ events: [EventRecord]) -> ReportData {
    ReportData(rangeStart: Date(timeIntervalSince1970: 1_784_000_000),
               rangeEnd: Date(timeIntervalSince1970: 1_784_100_000),
               events: events, gaps: [],
               coverage: CoverageTotals(monitoredSeconds: 3600, gapSeconds: 0, gapCount: 0),
               dailyCounts: [], bandLowHz: 0, bandHighHz: 0, thresholdDBFS: 0,
               hasBandInfo: !events.isEmpty)
}

@Test func testReportBassBandDoesNotFlagSpeech() {
    #expect(report([ev(bandLow: 20, bandHigh: 120)]).mayContainSpeech == false)
}

@Test func testReportBeepingBandFlagsSpeech() {
    #expect(report([ev(bandLow: 1000, bandHigh: 4000)]).mayContainSpeech)
}

@Test func testReportFlagsSpeechIfAnyEventOverlaps() {
    // One bass event, one beeping event → flagged (the beeping clip can carry speech).
    #expect(report([ev(bandLow: 20, bandHigh: 120), ev(bandLow: 1000, bandHigh: 4000)]).mayContainSpeech)
}

@Test func testEmptyReportDoesNotFlagSpeech() {
    #expect(report([]).mayContainSpeech == false)
}
