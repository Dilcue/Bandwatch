import Testing
import Foundation
@testable import BandwatchCore

private func tempDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("spans-\(UUID().uuidString)")
        .appendingPathComponent("events.sqlite")
}

@Test func testOpenSpanInsertsRowWithEndedAtEqualToStart() throws {
    let url = tempDBURL()
    let s = try EventStore(url: url)
    let start = Date(timeIntervalSince1970: 1_784_000_000)
    let id = try s.openSpan(startedAt: start)
    let rows = try s.spans(from: start.addingTimeInterval(-10), to: start.addingTimeInterval(10))
    #expect(rows.count == 1)
    #expect(rows[0].id == id)
    #expect(abs(rows[0].startedAt.timeIntervalSince(start)) < 1)
    // ended_at is set at open, never NULL, initially == started_at
    #expect(abs(rows[0].endedAt.timeIntervalSince(start)) < 1)
}

@Test func testUpdateSpanEndRollsEndedAtForward() throws {
    let url = tempDBURL()
    let s = try EventStore(url: url)
    let start = Date(timeIntervalSince1970: 1_784_000_000)
    let id = try s.openSpan(startedAt: start)
    let later = start.addingTimeInterval(120)
    try s.updateSpanEnd(id: id, endedAt: later)
    let rows = try s.spans(from: start, to: later.addingTimeInterval(10))
    #expect(rows.count == 1)
    #expect(abs(rows[0].endedAt.timeIntervalSince(later)) < 1)
}

@Test func testSpansOverlapFilter() throws {
    let url = tempDBURL()
    let s = try EventStore(url: url)
    let base = Date(timeIntervalSince1970: 1_784_000_000)
    let id = try s.openSpan(startedAt: base)                       // span [base, base+300]
    try s.updateSpanEnd(id: id, endedAt: base.addingTimeInterval(300))
    // range entirely before the span → no overlap
    #expect(try s.spans(from: base.addingTimeInterval(-100), to: base.addingTimeInterval(-10)).isEmpty)
    // range entirely after → no overlap
    #expect(try s.spans(from: base.addingTimeInterval(400), to: base.addingTimeInterval(500)).isEmpty)
    // range straddling the start → overlaps
    #expect(try s.spans(from: base.addingTimeInterval(-50), to: base.addingTimeInterval(50)).count == 1)
}

@Test func testSpansToleratesMissingTableOnReadOnly() throws {
    // A DB created before this feature has no monitoring_spans table. Opened
    // read-only (no DDL permitted), spans(...) must return [] rather than throw.
    let url = tempDBURL()
    // Create a DB the OLD way: events/gaps only, no spans table.
    let legacy = try EventStore(legacyNoSpansURL: url)
    legacy.close()
    let ro = try EventStore(readOnlyURL: url)
    let rows = try ro.spans(from: Date(timeIntervalSince1970: 0),
                            to: Date(timeIntervalSince1970: 2_000_000_000))
    #expect(rows.isEmpty)
}

@Test func testMigrationCreatesTableAndPreservesExistingData() throws {
    // Open the legacy DB read-WRITE with the current EventStore: it must create
    // the monitoring_spans table (CREATE TABLE IF NOT EXISTS) without disturbing events.
    let url = tempDBURL()
    let legacy = try EventStore(legacyNoSpansURL: url)
    _ = try legacy.insertEvent(startedAt: Date(timeIntervalSince1970: 1_784_000_000),
                               durationSec: 1, peakDBFS: -10, meanDBFS: -20,
                               band: try #require(FrequencyBand(lowHz: 40, highHz: 120)),
                               thresholdDBFS: -30, deviceUID: "dev", clipPath: "/x.flac")
    legacy.close()
    let s = try EventStore(url: url)                    // current schema → creates spans table
    #expect(try s.allEvents().count == 1)               // pre-existing event untouched
    let id = try s.openSpan(startedAt: Date(timeIntervalSince1970: 1_784_000_100))
    #expect(id > 0)                                      // table now exists and is writable
}
