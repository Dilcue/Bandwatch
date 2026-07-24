import Testing
import Foundation
import SQLite3
@testable import BandwatchCore

private func tempDB() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwdb-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("t.sqlite")
}

private func makeStore() throws -> EventStore { try EventStore(url: tempDB()) }

/// Reads a column's raw stored text directly from the sqlite file, bypassing
/// `EventStore`'s parsing, so tests can assert on exactly what's on disk
/// (e.g. whether the offset is `Z` or `-05:00`).
private func rawColumnText(at url: URL, sql: String) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw EventStoreError.couldNotOpen("could not open for raw read")
    }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
        throw EventStoreError.sqlFailed("could not prepare raw read")
    }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, let text = sqlite3_column_text(st, 0) else {
        throw EventStoreError.sqlFailed("no row for raw read")
    }
    return String(cString: text)
}

private func insertOne(_ s: EventStore, at date: Date, peak: Double = -18.5,
                       clip: String = "/tmp/a.flac") throws -> Int64 {
    try s.insertEvent(startedAt: date, durationSec: 12.5, peakDBFS: peak, meanDBFS: -24.0,
                      band: .bassSubwoofer, thresholdDBFS: -40.0,
                      deviceUID: "DEV-1", clipPath: clip)
}

@Test func testCreatesSchemaAndStartsEmpty() throws {
    let s = try makeStore()
    #expect(try s.allEvents().isEmpty)
    #expect(try s.allGaps().isEmpty)
    s.close()
}

@Test func testInsertAndReadBackEvent() throws {
    let s = try makeStore()
    let when = Date(timeIntervalSince1970: 1_784_000_000)
    let id = try insertOne(s, at: when)
    #expect(id > 0)

    let all = try s.allEvents()
    #expect(all.count == 1)
    let e = all[0]
    #expect(e.id == id)
    #expect(abs(e.durationSec - 12.5) < 0.001)
    #expect(abs(e.peakDBFS - (-18.5)) < 0.001)
    #expect(abs(e.bandLowHz - 20) < 0.001)
    #expect(abs(e.bandHighHz - 120) < 0.001)
    #expect(e.deviceUID == "DEV-1")
    #expect(e.clipPath == "/tmp/a.flac")
    // Timestamp round-trips to the same second.
    #expect(abs(e.startedAt.timeIntervalSince1970 - when.timeIntervalSince1970) < 1.0)
    s.close()
}

@Test func testStoresBandPerEventNotCurrentConfig() throws {
    let s = try makeStore()
    let d = Date()
    _ = try s.insertEvent(startedAt: d, durationSec: 1, peakDBFS: -10, meanDBFS: -20,
                          band: .bassSubwoofer, thresholdDBFS: -40,
                          deviceUID: "D", clipPath: "/a")
    _ = try s.insertEvent(startedAt: d.addingTimeInterval(60), durationSec: 1,
                          peakDBFS: -10, meanDBFS: -20,
                          band: .beeping, thresholdDBFS: -30,
                          deviceUID: "D", clipPath: "/b")
    let all = try s.allEvents()
    #expect(all.count == 2)
    // Historical rows keep the band they were recorded with.
    #expect(Set(all.map { $0.bandLowHz }) == Set([20.0, 1000.0]))
    s.close()
}

@Test func testDateRangeQuery() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_784_000_000)
    for i in 0..<5 { _ = try insertOne(s, at: base.addingTimeInterval(Double(i) * 3600)) }
    let mid = try s.events(from: base.addingTimeInterval(3500),
                           to: base.addingTimeInterval(7300))
    #expect(mid.count == 2)
    s.close()
}

@Test func testEventsAreOrderedByTime() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_784_000_000)
    _ = try insertOne(s, at: base.addingTimeInterval(200))
    _ = try insertOne(s, at: base)
    _ = try insertOne(s, at: base.addingTimeInterval(100))
    let all = try s.allEvents()
    #expect(all[0].startedAt <= all[1].startedAt)
    #expect(all[1].startedAt <= all[2].startedAt)
    s.close()
}

@Test func testOpenAndCloseGap() throws {
    let s = try makeStore()
    let start = Date(timeIntervalSince1970: 1_784_000_000)
    let id = try s.openGap(startedAt: start, reason: .deviceLost)
    var open = try s.openGaps()
    #expect(open.count == 1)
    #expect(open[0].reason == .deviceLost)
    #expect(open[0].endedAt == nil)

    try s.closeGap(id: id, endedAt: start.addingTimeInterval(30))
    open = try s.openGaps()
    #expect(open.isEmpty)
    let all = try s.allGaps()
    #expect(all.count == 1)
    #expect(all[0].endedAt != nil)
    s.close()
}

@Test func testAllGapReasonsRoundTrip() throws {
    let s = try makeStore()
    for (i, r) in GapReason.allCases.enumerated() {
        _ = try s.openGap(startedAt: Date(timeIntervalSince1970: 1_784_000_000 + Double(i)),
                          reason: r)
    }
    let all = try s.allGaps()
    #expect(Set(all.map { $0.reason }) == Set(GapReason.allCases))
    s.close()
}

@Test func testDeleteOldEventsReturnsClipPaths() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_784_000_000)
    _ = try insertOne(s, at: base, clip: "/old1.flac")
    _ = try insertOne(s, at: base.addingTimeInterval(60), clip: "/old2.flac")
    _ = try insertOne(s, at: base.addingTimeInterval(100_000), clip: "/new.flac")

    let deleted = try s.deleteEvents(olderThan: base.addingTimeInterval(1000))
    #expect(Set(deleted) == Set(["/old1.flac", "/old2.flac"]))
    #expect(try s.allEvents().count == 1)
    #expect(try s.allEvents()[0].clipPath == "/new.flac")
    s.close()
}

@Test func testReopeningKeepsData() throws {
    let url = tempDB()
    let s1 = try EventStore(url: url)
    _ = try insertOne(s1, at: Date())
    s1.close()

    let s2 = try EventStore(url: url)
    #expect(try s2.allEvents().count == 1)
    s2.close()
}

// MARK: Timestamp offset (Finding 1)

@Test func testStartedAtRoundTripsWithPinnedTimeZone() throws {
    let zone = try #require(TimeZone(identifier: "America/Chicago"))
    let url = tempDB()
    let s = try EventStore(url: url, timeZone: zone)
    let when = Date(timeIntervalSince1970: 1_784_000_000)
    _ = try insertOne(s, at: when)
    let e = try #require(try s.allEvents().first)
    // Same instant, not just same wall-clock reading: round-tripping through
    // the offset-qualified formatter must not shift the underlying instant.
    #expect(abs(e.startedAt.timeIntervalSince1970 - when.timeIntervalSince1970) < 1.0)
    s.close()
}

@Test func testStoredTimestampCarriesExplicitOffsetNotZ() throws {
    let zone = try #require(TimeZone(identifier: "America/Chicago"))
    let url = tempDB()
    let s = try EventStore(url: url, timeZone: zone)
    // July: America/Chicago is in CDT, UTC-05:00.
    let when = Date(timeIntervalSince1970: 1_784_000_000)
    _ = try insertOne(s, at: when)
    s.close()

    let stored = try rawColumnText(at: url, sql: "SELECT started_at FROM events LIMIT 1;")
    #expect(!stored.hasSuffix("Z"))
    #expect(stored.hasSuffix("-05:00"))
}

// MARK: Delete race (Finding 2)

@Test func testDeleteEventsRETURNINGMatchesDisappearedRows() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_784_000_000)
    let keptId = try insertOne(s, at: base.addingTimeInterval(100_000), clip: "/new.flac")
    var doomedIds: Set<Int64> = []
    doomedIds.insert(try insertOne(s, at: base, clip: "/old1.flac"))
    doomedIds.insert(try insertOne(s, at: base.addingTimeInterval(60), clip: "/old2.flac"))

    let before = Set(try s.allEvents().map(\.id))
    #expect(before == doomedIds.union([keptId]))

    let deleted = try s.deleteEvents(olderThan: base.addingTimeInterval(1000))
    let after = Set(try s.allEvents().map(\.id))

    // Exactly the rows that vanished from the table are the ones whose paths
    // came back — nothing is deleted silently.
    let disappearedIds = before.subtracting(after)
    #expect(disappearedIds == doomedIds)
    #expect(Set(deleted) == Set(["/old1.flac", "/old2.flac"]))
    s.close()
}

// MARK: Unknown gap reason (Finding 3)

@Test func testUnrecognisedGapReasonReadsAsUnknownNotShutdown() throws {
    let url = tempDB()
    let s = try EventStore(url: url)
    // Simulate a row written by a future build with a reason this version
    // doesn't know about, by inserting the raw string directly via SQL.
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        Issue.record("could not open db for raw insert")
        return
    }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(
        db, "INSERT INTO gaps (started_at, reason) VALUES ('2026-07-20T00:00:00-05:00', 'power_outage');",
        -1, &st, nil) == SQLITE_OK else {
        Issue.record("could not prepare raw insert")
        return
    }
    defer { sqlite3_finalize(st) }
    #expect(sqlite3_step(st) == SQLITE_DONE)

    let all = try s.allGaps()
    #expect(all.count == 1)
    #expect(all[0].reason == .unknown)
    #expect(all[0].reason != .shutdown)
    s.close()
}

@Test func testResolveStaleOpenGapsClosesPriorRunGapsAtLastHeartbeat() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // A prior run: a span heartbeated to base+120, and a gap opened at base+60
    // that was never closed (crash).
    let spanID = try s.openSpan(startedAt: base)
    try s.updateSpanEnd(id: spanID, endedAt: base.addingTimeInterval(120))
    let stale = try s.openGap(startedAt: base.addingTimeInterval(60), reason: .deviceLost)
    // A gap the CURRENT run opened (after the launch cutoff) must be left alone.
    let current = try s.openGap(startedAt: base.addingTimeInterval(600), reason: .deviceLost)

    let cutoff = base.addingTimeInterval(300)   // "this process launched at base+300"
    let resolved = try s.resolveStaleOpenGaps(before: cutoff)

    #expect(resolved == 1)
    #expect(try s.openGaps().map { $0.id } == [current])   // only the current-run gap stays open
    let closed = try s.allGaps().first { $0.id == stale }!
    #expect(closed.reason == .deviceLost)                  // original reason preserved
    #expect(closed.endedAt != nil)
    // Closed at the last heartbeat (base+120), not "now" and not its own start.
    #expect(abs(closed.endedAt!.timeIntervalSince(base.addingTimeInterval(120))) < 1)
}

@Test func testResolveStaleOpenGapsFallsBackToStartWhenNoLaterSpan() throws {
    let s = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // Gap opened after every span heartbeat -> no span at/after its start.
    let spanID = try s.openSpan(startedAt: base)
    try s.updateSpanEnd(id: spanID, endedAt: base.addingTimeInterval(10))
    let stale = try s.openGap(startedAt: base.addingTimeInterval(50), reason: .captureStalled)

    let resolved = try s.resolveStaleOpenGaps(before: base.addingTimeInterval(300))
    #expect(resolved == 1)
    let closed = try s.allGaps().first { $0.id == stale }!
    // No later heartbeat -> closed at its own start (zero-duration, never negative).
    #expect(abs(closed.endedAt!.timeIntervalSince(base.addingTimeInterval(50))) < 1)
}
