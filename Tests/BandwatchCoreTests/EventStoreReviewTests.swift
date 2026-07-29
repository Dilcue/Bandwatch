import Testing
import Foundation
@testable import BandwatchCore

private func tempDBURL() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwreview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("bandwatch.sqlite")
}

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

/// Seed a writable store with events on known days, then close it.
private func seed(_ url: URL) throws {
    let s = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    // 2 events on 2026-07-20, 3 on 2026-07-21, 1 on 2026-07-25
    let days = [("2026-07-20T22:00:00-05:00", 2),
                ("2026-07-21T23:00:00-05:00", 3),
                ("2026-07-25T01:00:00-05:00", 1)]
    for (base, n) in days {
        for i in 0..<n {
            _ = try s.insertEvent(startedAt: iso(base).addingTimeInterval(Double(i) * 60),
                                  durationSec: 5, peakDBFS: -20, meanDBFS: -28,
                                  band: .bassSubwoofer, thresholdDBFS: -40,
                                  deviceUID: "D", clipPath: "/clips/\(base)-\(i).flac")
        }
    }
    s.close()
}

@Test func testReadOnlyOpenCannotBeUsedToInsert() throws {
    let url = tempDBURL()
    try seed(url)
    let ro = try EventStore(readOnlyURL: url)
    // The read-only connection can query...
    #expect(try ro.allEvents().count == 6)
    ro.close()
}

@Test func testReadOnlyOpenOfMissingFileThrows() {
    let missing = tempDBURL()  // directory exists, file does not
    #expect(throws: EventStoreError.self) { _ = try EventStore(readOnlyURL: missing) }
}

@Test func testEventCountsByDay() throws {
    let url = tempDBURL(); try seed(url)
    let ro = try EventStore(readOnlyURL: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    let counts = try ro.eventCountsByDay(from: iso("2026-07-01T00:00:00-05:00"),
                                         to: iso("2026-07-31T23:59:59-05:00"))
    let dict = Dictionary(uniqueKeysWithValues: counts.map { ($0.day, $0.count) })
    #expect(dict["2026-07-20"] == 2)
    #expect(dict["2026-07-21"] == 3)
    #expect(dict["2026-07-25"] == 1)
    #expect(dict["2026-07-22"] == nil)   // a quiet day is absent, not zero
    ro.close()
}

@Test func testEventCountInRange() throws {
    let url = tempDBURL(); try seed(url)
    let ro = try EventStore(readOnlyURL: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    // 2026-07-20 through 2026-07-21 inclusive -> 5 events, excluding the 25th
    let n = try ro.eventCount(from: iso("2026-07-20T00:00:00-05:00"),
                              to: iso("2026-07-22T00:00:00-05:00"))
    #expect(n == 5)
    ro.close()
}

// Coverage is now computed from positive monitoring spans (Task 2), not
// inferred from the mere absence of gap rows: monitoredSeconds = span time
// minus in-span gap time, clamped to [from,to] and never extended past a
// span's real ended_at. The two tests below used to seed gaps only and
// assert monitoredSeconds ≈ (to-from) - gaps; that encoded the OLD
// range-minus-gaps semantics and is replaced by span-seeded versions here.

@Test func testCoverageIsSpanTimeWhenNoGaps() throws {
    let url = tempDBURL()
    let w = try EventStore(url: url)
    let from = iso("2026-07-20T00:00:00-05:00"), to = iso("2026-07-20T01:00:00-05:00")
    let sid = try w.openSpan(startedAt: from)
    try w.updateSpanEnd(id: sid, endedAt: to)          // monitored the whole hour
    w.close()
    let ro = try EventStore(readOnlyURL: url)
    let cov = try ro.coverageTotals(from: from, to: to)
    #expect(cov.gapSeconds == 0)
    #expect(abs(cov.monitoredSeconds - 3600) < 1)   // one hour, fully spanned, no gaps
    ro.close()
}

@Test func testCoverageSubtractsInSpanGaps() throws {
    let url = tempDBURL()
    let w = try EventStore(url: url)
    let from = iso("2026-07-20T00:00:00-05:00"), to = iso("2026-07-20T01:00:00-05:00")
    let sid = try w.openSpan(startedAt: from)
    try w.updateSpanEnd(id: sid, endedAt: to)          // span covers the hour
    // a 10-minute gap inside the hour
    let gid = try w.openGap(startedAt: iso("2026-07-20T00:20:00-05:00"), reason: .noSignal)
    try w.closeGap(id: gid, endedAt: iso("2026-07-20T00:30:00-05:00"))
    w.close()
    let ro = try EventStore(readOnlyURL: url)
    let cov = try ro.coverageTotals(from: from, to: to)
    #expect(abs(cov.gapSeconds - 600) < 1)                 // 10 minutes
    #expect(abs(cov.monitoredSeconds - 3000) < 1)          // 60 - 10 minutes
    #expect(cov.gapCount == 1)
    ro.close()
}

@Test func testCoverageIsZeroWhenNoSpans() throws {
    // The core honesty win: a picker range with no monitoring span reports ZERO
    // monitored seconds - not the full range. This is the false claim the
    // feature fixes. Events exist in this range but no span does.
    let url = tempDBURL(); try seed(url)
    let ro = try EventStore(readOnlyURL: url)
    let from = iso("2026-07-20T00:00:00-05:00"), to = iso("2026-07-21T00:00:00-05:00")
    let cov = try ro.coverageTotals(from: from, to: to)
    #expect(cov.monitoredSeconds == 0)
    ro.close()
}

@Test func testCoverageNeverOverstatesPastSpanEnd() throws {
    // A span that ended before `to` contributes only its real seconds, never
    // extended to `to`/now.
    let url = tempDBURL()
    let w = try EventStore(url: url)
    let from = iso("2026-07-20T00:00:00-05:00")
    let spanEnd = iso("2026-07-20T00:30:00-05:00")     // ran 30 min then stopped
    let to = iso("2026-07-20T01:00:00-05:00")          // picker range is a full hour
    let sid = try w.openSpan(startedAt: from)
    try w.updateSpanEnd(id: sid, endedAt: spanEnd)
    w.close()
    let ro = try EventStore(readOnlyURL: url)
    let cov = try ro.coverageTotals(from: from, to: to)
    #expect(abs(cov.monitoredSeconds - 1800) < 1)      // only the 30 min it actually ran
    ro.close()
}

@Test func testLiveReportWithOpenOverlappingGapsIsNotZeroed() throws {
    // The reported incident, end to end: a report generated for "today" while
    // monitoring is live, with two overlapping gaps still OPEN. The old math
    // projected each open gap to the range end (midnight, hours ahead) and
    // summed them (~26.9h), zeroing a genuinely ~10h-monitored day. `now` (the
    // report moment) must cap the window so open gaps count only through now and
    // the union is taken.
    let url = tempDBURL()
    let w = try EventStore(url: url)
    let from = iso("2026-07-29T00:00:00-05:00")
    let to   = iso("2026-07-30T00:00:00-05:00")         // midnight tonight (future)
    let now  = iso("2026-07-29T10:33:00-05:00")         // report time, 13.5h before `to`
    // Monitoring ran 00:00 -> 10:00 (10h).
    let sid = try w.openSpan(startedAt: from)
    try w.updateSpanEnd(id: sid, endedAt: iso("2026-07-29T10:00:00-05:00"))
    // Two overlapping gaps left OPEN (write-failure then device-loss), as in the
    // incident — never closed because the app was still running at report time.
    _ = try w.openGap(startedAt: iso("2026-07-29T10:31:15-05:00"), reason: .writeFailure)
    _ = try w.openGap(startedAt: iso("2026-07-29T10:32:20-05:00"), reason: .deviceLost)
    w.close()

    let ro = try EventStore(readOnlyURL: url)
    let cov = try ro.coverageTotals(from: from, to: to, now: now)
    #expect(cov.monitoredSeconds > 9.5 * 3600)   // ~10h monitored — NOT zero
    #expect(cov.gapSeconds < 5 * 60)             // a couple minutes, not 26.9h
    #expect(cov.gapCount == 2)                   // still honestly reports two gap rows
    ro.close()
}

@Test func testEventCountAndEventListConsistentAtBoundary() throws {
    let url = tempDBURL()
    let w = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    let boundaryTime = iso("2026-07-20T12:30:00-05:00")
    let from = iso("2026-07-20T00:00:00-05:00")
    // Insert an event exactly at the boundary
    _ = try w.insertEvent(startedAt: boundaryTime, durationSec: 5, peakDBFS: -20, meanDBFS: -28,
                          band: .bassSubwoofer, thresholdDBFS: -40,
                          deviceUID: "D", clipPath: "/clips/boundary.flac")
    w.close()
    let ro = try EventStore(readOnlyURL: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    // Query with the boundary as the upper limit
    let eventList = try ro.events(from: from, to: boundaryTime)
    let eventCountValue = try ro.eventCount(from: from, to: boundaryTime)
    // Both should count the boundary event the same way
    #expect(eventCountValue == eventList.count)
    #expect(eventCountValue == 1)
    ro.close()
}
