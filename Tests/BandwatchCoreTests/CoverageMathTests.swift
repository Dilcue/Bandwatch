import Testing
import Foundation
@testable import BandwatchCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let hour = 3600.0
private func span(_ a: Double, _ b: Double) -> SpanRecord {
    SpanRecord(id: 0, startedAt: t0 + a * hour, endedAt: t0 + b * hour)
}
private func gap(_ a: Double, _ b: Double?) -> GapRecord {
    GapRecord(id: 0, startedAt: t0 + a * hour,
              endedAt: b.map { t0 + $0 * hour }, reason: .noSignal)
}

// MARK: - The regression this whole file exists for

@Test func testLiveOpenGapsAreNotProjectedIntoTheFutureAndDoNotZeroMonitoring() {
    // Reproduces the reported incident: a report for "today" (range end at
    // midnight tonight) generated at ~10.5h while monitoring is live with two
    // OVERLAPPING open gaps. The old sum-and-clamp-to-`to` math extended each
    // open gap ~13.5h into the future and double-counted them (~26.9h), forcing
    // monitored = max(span - gap, 0) to 0. Correct: gaps count only through now
    // and union once, so monitored ≈ the real span time.
    let spans = [span(0, 10)]                                  // ran 00:00 -> 10:00
    let gaps  = [gap(10.52, nil), gap(10.55, nil)]             // two open gaps ~10:31 & ~10:33
    let now   = t0 + 10.6 * hour                               // report time
    let to    = t0 + 24 * hour                                 // midnight tonight (future)

    let r = CoverageMath.totals(spans: spans, gaps: gaps, from: t0, to: to, now: now)

    #expect(r.monitoredSeconds > 9.5 * hour)   // ~10h, emphatically not zero
    #expect(r.gapSeconds < 10 * 60)            // a few minutes, not 26.9h
}

// MARK: - Component properties

@Test func testWindowIsCappedAtNowSoTheFutureIsNeverCounted() {
    // Range ends 10h ahead of now; a span that (impossibly) claimed to run to the
    // range end still only counts elapsed time up to now.
    let r = CoverageMath.totals(spans: [span(0, 24)], gaps: [],
                                from: t0, to: t0 + 24 * hour, now: t0 + 5 * hour)
    #expect(abs(r.monitoredSeconds - 5 * hour) < 1)
}

@Test func testOpenGapCountsOnlyThroughNowNotToRangeEnd() {
    let r = CoverageMath.totals(spans: [span(0, 5)], gaps: [gap(4, nil)],
                                from: t0, to: t0 + 10 * hour, now: t0 + 4.5 * hour)
    #expect(abs(r.gapSeconds - 0.5 * hour) < 1)          // 30 min open, not 6h to `to`
    #expect(abs(r.monitoredSeconds - 4.0 * hour) < 1)    // 4.5h window - 0.5h gap
}

@Test func testOverlappingGapsAreUnionedNotSummed() {
    // Two overlapping gaps [1h,3h] and [2h,3.5h] -> union [1h,3.5h] = 2.5h,
    // NOT the 3.5h their durations sum to.
    let r = CoverageMath.totals(spans: [span(0, 4)], gaps: [gap(1, 3), gap(2, 3.5)],
                                from: t0, to: t0 + 4 * hour, now: t0 + 100 * hour)
    #expect(abs(r.gapSeconds - 2.5 * hour) < 1)
    #expect(abs(r.monitoredSeconds - 1.5 * hour) < 1)    // 4h - 2.5h
}

@Test func testDisjointGapsStillSumNormally() {
    let r = CoverageMath.totals(spans: [span(0, 4)], gaps: [gap(1, 1.5), gap(3, 3.5)],
                                from: t0, to: t0 + 4 * hour, now: t0 + 100 * hour)
    #expect(abs(r.gapSeconds - 1.0 * hour) < 1)          // 0.5h + 0.5h, no overlap
}

@Test func testOverlappingSpansAreUnionedNotDoubleCounted() {
    // Redundant/overlapping spans must not overstate monitored time.
    let r = CoverageMath.totals(spans: [span(0, 3), span(2, 4)], gaps: [],
                                from: t0, to: t0 + 4 * hour, now: t0 + 100 * hour)
    #expect(abs(r.monitoredSeconds - 4 * hour) < 1)      // union [0,4] = 4h, not 5h
}

@Test func testNowBeforeRangeStartYieldsZero() {
    let r = CoverageMath.totals(spans: [span(0, 4)], gaps: [],
                                from: t0 + 2 * hour, to: t0 + 4 * hour, now: t0)
    #expect(r.monitoredSeconds == 0)
    #expect(r.gapSeconds == 0)
}
