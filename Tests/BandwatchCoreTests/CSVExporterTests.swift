import Testing
import Foundation
@testable import BandwatchCore

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

private func event(clip: String) -> EventRecord {
    EventRecord(id: 1, startedAt: iso("2026-07-21T23:41:07-05:00"), durationSec: 5.18,
                peakDBFS: -29.3, meanDBFS: -37.9, bandLowHz: 20, bandHighHz: 120,
                thresholdDBFS: -40, deviceUID: "DEV-1", clipPath: clip)
}

@Test func testEventsCSVHeaderAndRow() {
    let csv = CSVExporter.eventsCSV([event(clip: "/a/b.flac")])
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines[0] == "id,started_at,duration_sec,peak_dbfs,mean_dbfs,band_low_hz,band_high_hz,threshold_dbfs,device_uid,clip_path")
    #expect(lines[1].contains("2026-07-21T23:41:07-05:00"))
    #expect(lines[1].contains("-29.3"))
    #expect(lines[1].hasSuffix("\"/a/b.flac\""))   // clip_path always quoted
}

@Test func testClipPathWithCommaIsQuotedAndEscaped() {
    let csv = CSVExporter.eventsCSV([event(clip: "/weird, name/\"x\".flac")])
    // internal quotes doubled, whole field wrapped
    #expect(csv.contains("\"/weird, name/\"\"x\"\".flac\""))
}

@Test func testEmptyEventsIsHeaderOnly() {
    let csv = CSVExporter.eventsCSV([])
    #expect(csv.split(separator: "\n").count == 1)
}

@Test func testGapsCSVIncludesReasonAndOpenGap() {
    let open = GapRecord(id: 1, startedAt: iso("2026-07-21T02:00:00-05:00"),
                         endedAt: nil, reason: .noSignal)
    let closed = GapRecord(id: 2, startedAt: iso("2026-07-21T03:00:00-05:00"),
                           endedAt: iso("2026-07-21T03:05:00-05:00"), reason: .captureStalled)
    let csv = CSVExporter.gapsCSV([open, closed])
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines[0] == "id,started_at,ended_at,reason")

    // open gap: ended_at is empty, creating ",," pattern
    let openFields = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(openFields.count == 4)
    #expect(openFields[2].isEmpty)  // ended_at is empty
    #expect(openFields[3] == "no_signal")  // reason is fourth field
    #expect(lines[1].contains(",,"))  // open gap contains empty ended_at

    // closed gap: has all four fields
    let closedFields = lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(closedFields.count == 4)
    #expect(!closedFields[2].isEmpty)  // ended_at is not empty
    #expect(closedFields[3] == "capture_stalled")  // reason is fourth field

    // all rows have same column count as header
    for (i, line) in lines.enumerated() where i > 0 {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields.count == 4, "Row \(i) has \(fields.count) fields, expected 4")
    }
}
