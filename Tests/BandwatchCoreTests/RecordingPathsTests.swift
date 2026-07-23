import Testing
import Foundation
@testable import BandwatchCore

private func makeDate(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private let paths = RecordingPaths(root: URL(fileURLWithPath: "/tmp/bwtest"))

@Test func testDirectoryLayout() {
    #expect(paths.archiveDirectory.path == "/tmp/bwtest/archive")
    #expect(paths.eventsDirectory.path == "/tmp/bwtest/events")
    #expect(paths.databaseURL.lastPathComponent == "bandwatch.sqlite")
}

@Test func testTimestampNameHasNoColons() {
    let d = makeDate("2026-07-20T23:41:07Z")
    let name = paths.timestampName(for: d)
    #expect(!name.contains(":"))
    #expect(name.contains("T"))
}

@Test func testArchiveSegmentURLShape() {
    let d = makeDate("2026-07-20T22:00:00Z")
    let url = paths.archiveSegmentURL(startingAt: d)
    #expect(url.pathExtension == "flac")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "archive")
    // day directory sits between archive/ and the file
    let day = url.deletingLastPathComponent().lastPathComponent
    #expect(day.count == 10)          // yyyy-MM-dd
    #expect(day.filter { $0 == "-" }.count == 2)
}

@Test func testEventClipURLShape() {
    let d = makeDate("2026-07-20T23:41:07Z")
    let url = paths.eventClipURL(startingAt: d)
    #expect(url.pathExtension == "flac")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "events")
}

@Test func testDayDirectoryGroupsSameDayTogether() {
    let a = paths.archiveSegmentURL(startingAt: makeDate("2026-07-20T22:00:00Z"))
    let b = paths.archiveSegmentURL(startingAt: makeDate("2026-07-20T23:00:00Z"))
    #expect(a.deletingLastPathComponent() == b.deletingLastPathComponent())
}

@Test func testDistinctTimesProduceDistinctFiles() {
    let a = paths.archiveSegmentURL(startingAt: makeDate("2026-07-20T22:00:00Z"))
    let b = paths.archiveSegmentURL(startingAt: makeDate("2026-07-20T23:00:00Z"))
    #expect(a != b)
}

@Test func testDefaultRootIsUnderApplicationSupport() {
    let r = RecordingPaths.defaultRoot()
    #expect(r.path.contains("Application Support"))
    #expect(r.lastPathComponent == "Bandwatch")
}

@Test func testMillisecondApartDatesProduceDistinctURLs() {
    let a = makeDate("2026-07-20T23:41:07Z")
    let b = a.addingTimeInterval(0.001)

    let archiveA = paths.archiveSegmentURL(startingAt: a)
    let archiveB = paths.archiveSegmentURL(startingAt: b)
    #expect(archiveA != archiveB)

    let eventA = paths.eventClipURL(startingAt: a)
    let eventB = paths.eventClipURL(startingAt: b)
    #expect(eventA != eventB)
}

@Test func testTimestampNameContainsUTCOffset() {
    let d = makeDate("2026-07-20T23:41:07Z")
    let name = paths.timestampName(for: d)
    // Name must end with a 4-digit UTC offset preceded by + or -.
    let suffix = name.suffix(5)
    let sign = suffix.first!
    let digits = suffix.dropFirst()
    let isAllDigits = digits.allSatisfy { $0.isNumber }
    #expect(sign == "+" || sign == "-")
    #expect(digits.count == 4)
    #expect(isAllDigits)
}

@Test func testDSTFallBackProducesDistinctNames() {
    // In America/New_York, clocks fall back from 2am to 1am on 2026-11-01.
    // 2026-11-01T05:30:00Z is 1:30am EDT (-0400).
    // 2026-11-01T06:30:00Z is 1:30am EST (-0500).
    // Both render as the same local wall-clock "1:30am" but are distinct
    // instants and must produce distinct, unambiguous filenames.
    let nyPaths = RecordingPaths(
        root: URL(fileURLWithPath: "/tmp/bwtest"),
        timeZone: TimeZone(identifier: "America/New_York")!
    )
    let a = makeDate("2026-11-01T05:30:00Z")
    let b = makeDate("2026-11-01T06:30:00Z")

    let nameA = nyPaths.timestampName(for: a)
    let nameB = nyPaths.timestampName(for: b)
    #expect(nameA != nameB)
    #expect(nameA.contains("01-30-00"))
    #expect(nameB.contains("01-30-00"))
    #expect(nameA.hasSuffix("-0400"))
    #expect(nameB.hasSuffix("-0500"))

    let urlA = nyPaths.archiveSegmentURL(startingAt: a)
    let urlB = nyPaths.archiveSegmentURL(startingAt: b)
    #expect(urlA != urlB)
}
