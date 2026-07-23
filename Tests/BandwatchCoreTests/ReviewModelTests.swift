import Testing
import Foundation
@testable import BandwatchCore

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
}
private func tempDBURL() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bwrm-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("bandwatch.sqlite")
}
private func seed(_ url: URL) throws {
    let s = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    for i in 0..<3 {
        _ = try s.insertEvent(startedAt: iso("2026-07-21T23:00:00-05:00").addingTimeInterval(Double(i)*300),
                              durationSec: 5, peakDBFS: -20, meanDBFS: -28, band: .bassSubwoofer,
                              thresholdDBFS: -40, deviceUID: "D", clipPath: "/c\(i).flac")
    }
    s.close()
}

@MainActor @Test func testLoadPopulatesEventsInRange() throws {
    let url = tempDBURL(); try seed(url)
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00")
    m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    #expect(m.loadError == nil)
    #expect(m.events.count == 3)
    #expect(m.dailyCounts.first(where: { $0.day == "2026-07-21" })?.count == 3)
}

@MainActor @Test func testMissingDatabaseIsAnEmptyStateNotACrash() {
    let m = ReviewModel(databaseURL: tempDBURL())   // never seeded
    m.load()
    #expect(m.events.isEmpty)
    #expect(m.loadError != nil)   // surfaced, not fatal
}

@MainActor @Test func testSelectionResolvesToEvent() throws {
    let url = tempDBURL(); try seed(url)
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    m.selectedEventID = m.events.first!.id
    #expect(m.selectedEvent?.id == m.events.first!.id)
}

@MainActor @Test func testEventsForDayWindow() throws {
    let url = tempDBURL(); try seed(url)
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-23T00:00:00-05:00")
    m.load()
    // the seeded events are at 23:00 on the 21st -> belong to the calendar day of the 21st
    let day = m.eventsForDay(of: iso("2026-07-21T12:00:00-05:00"))
    #expect(day.count == 3)
}

@MainActor @Test func testEventsForDayIncludesEarlyMorningEvents() throws {
    // Pins the calendar-day semantics: a 2am event on the 21st belongs to the
    // 21st's calendar day. Under the old 6pm-6am "night" window this event
    // would instead have belonged to the night OF the 20th (6pm on the 20th
    // to 6am on the 21st), disagreeing with the calendar heatmap, which
    // buckets purely by local calendar day.
    let url = tempDBURL()
    let s = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    _ = try s.insertEvent(startedAt: iso("2026-07-21T02:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                          meanDBFS: -28, band: .bassSubwoofer, thresholdDBFS: -40,
                          deviceUID: "D", clipPath: "/c0.flac")
    s.close()

    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-20T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()

    let day21 = m.eventsForDay(of: iso("2026-07-21T12:00:00-05:00"))
    #expect(day21.count == 1)

    let day20 = m.eventsForDay(of: iso("2026-07-20T12:00:00-05:00"))
    #expect(day20.isEmpty)
}

@MainActor @Test func testDayStateReflectsCountsAndCoverage() throws {
    let url = tempDBURL(); try seed(url)
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    #expect(m.dayState(for: iso("2026-07-21T12:00:00-05:00"), monitoredSecondsThatDay: 80000) == .events(3))
    #expect(m.dayState(for: iso("2026-07-19T12:00:00-05:00"), monitoredSecondsThatDay: 80000) == .quiet)
    #expect(m.dayState(for: iso("2026-07-19T12:00:00-05:00"), monitoredSecondsThatDay: 100) == .notMonitored)
}

@MainActor @Test func testMonitoredSecondsIsSpanMinusGap() throws {
    let url = tempDBURL()
    let store = try EventStore(url: url)
    let day = iso("2026-07-19T00:00:00-05:00")            // local midnight
    let sid = try store.openSpan(startedAt: day)
    try store.updateSpanEnd(id: sid, endedAt: day.addingTimeInterval(7200))  // 2h span
    let gid = try store.openGap(startedAt: day.addingTimeInterval(600), reason: .noSignal)
    try store.closeGap(id: gid, endedAt: day.addingTimeInterval(1200))       // 10min gap
    store.close()
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = day.addingTimeInterval(-86400)
    m.rangeEnd = day.addingTimeInterval(2 * 86400)
    m.load()
    #expect(abs(m.monitoredSeconds(on: day) - (7200 - 600)) < 1)
}

@MainActor @Test func testMonitoredSecondsIsZeroForUnmonitoredDay() throws {
    let url = tempDBURL()
    _ = try EventStore(url: url)                          // empty DB, no spans
    let m = ReviewModel(databaseURL: url)
    m.load()
    let someDay = iso("2026-07-19T12:00:00-05:00")
    #expect(m.monitoredSeconds(on: someDay) == 0)         // no span → not monitored
}

@MainActor @Test func testCurrentReportDataAfterLoadIncludesEventsRangeAndBand() throws {
    let url = tempDBURL(); try seed(url)
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    let data = m.currentReportData()
    #expect(data != nil)
    #expect(data?.events.count == 3)
    #expect(data?.rangeStart == m.rangeStart)
    #expect(data?.rangeEnd == m.rangeEnd)
    #expect(data?.bandLowHz == m.events.first?.bandLowHz)
    #expect(data?.bandHighHz == m.events.first?.bandHighHz)
    #expect(data?.thresholdDBFS == m.events.first?.thresholdDBFS)
}

@MainActor @Test func testCurrentReportDataNilWhenNothingLoaded() {
    let m = ReviewModel(databaseURL: tempDBURL())   // never seeded / never loaded
    #expect(m.currentReportData() == nil)
}

@MainActor @Test func testCurrentReportDataNilAfterFailedLoad() {
    let m = ReviewModel(databaseURL: tempDBURL())   // never seeded
    m.load()   // fails: no such database
    #expect(m.currentReportData() == nil)
}

// MARK: - Finding 1 (superseded by span-based coverage): coverage now comes
// straight from `EventStore.coverageTotals`, which is itself span-based — a
// positive record of "the recorder was running" rather than an inference
// from the absence of gap rows. `currentReportData()` no longer needs (or
// performs) any clamp to an evidence-bearing window; it reports the honest
// span-derived figure directly, however wide the picker range is.

@MainActor @Test func testReportCoverageIsSpanBased() throws {
    let url = tempDBURL()
    let store = try EventStore(url: url)
    let start = iso("2026-07-19T20:00:00-05:00")
    let sid = try store.openSpan(startedAt: start)
    try store.updateSpanEnd(id: sid, endedAt: start.addingTimeInterval(4 * 3600))  // ran 4h
    store.close()
    let m = ReviewModel(databaseURL: url)
    m.rangeStart = start.addingTimeInterval(-30 * 86400)  // wide picker range
    m.rangeEnd = start.addingTimeInterval(30 * 86400)
    m.load()
    let data = m.currentReportData()
    #expect(data != nil)
    #expect(abs(data!.coverage.monitoredSeconds - 4 * 3600) < 1)  // the 4h it ran, not the 60-day range
}

@MainActor @Test func testCurrentReportDataMonitoredSecondsZeroWhenNoEvidenceAtAll() throws {
    let url = tempDBURL()
    // Create the database (so `load()` succeeds) but open no spans and
    // log no gaps in the queried range — no evidence monitoring ever ran.
    let s = try EventStore(url: url); s.close()

    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-06-22T00:00:00-05:00")
    m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    #expect(m.loadError == nil)

    let data = m.currentReportData()
    #expect(data != nil)
    // No spans exist in this range, so span-based coverage must report zero.
    #expect(data!.coverage.monitoredSeconds == 0)
}

// MARK: - Finding 2: band/threshold header must be honest for mixed or
// empty event sets, not silently derived from `events.first`.

@MainActor @Test func testCurrentReportDataEmptyEventsDoesNotClaimZeroZeroBand() throws {
    let url = tempDBURL()
    let s = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    // A monitored-but-quiet period: a logged gap but zero events in range.
    let gid = try s.openGap(startedAt: iso("2026-07-21T10:00:00-05:00"), reason: .noSignal)
    try s.closeGap(id: gid, endedAt: iso("2026-07-21T10:05:00-05:00"))
    s.close()

    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()
    #expect(m.events.isEmpty)

    let data = m.currentReportData()
    #expect(data != nil)
    // The header must be told there is no real band/threshold reading here —
    // never silently presented as a genuine "0–0 Hz" setting.
    #expect(data?.hasBandInfo == false)
}

@MainActor @Test func testCurrentReportDataFlagsMixedBandThresholdAcrossEvents() throws {
    let url = tempDBURL()
    let s = try EventStore(url: url, timeZone: TimeZone(identifier: "America/Chicago")!)
    _ = try s.insertEvent(startedAt: iso("2026-07-21T10:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                          meanDBFS: -28, band: .bassSubwoofer, thresholdDBFS: -40,
                          deviceUID: "D", clipPath: "/c0.flac")
    _ = try s.insertEvent(startedAt: iso("2026-07-21T11:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                          meanDBFS: -28, band: .applianceWhine, thresholdDBFS: -30,
                          deviceUID: "D", clipPath: "/c1.flac")
    s.close()

    let m = ReviewModel(databaseURL: url)
    m.rangeStart = iso("2026-07-21T00:00:00-05:00"); m.rangeEnd = iso("2026-07-22T00:00:00-05:00")
    m.load()

    let data = m.currentReportData()
    #expect(data?.hasBandInfo == true)
    #expect(data?.bandThresholdVaries == true)
}
