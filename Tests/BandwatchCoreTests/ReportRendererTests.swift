import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import BandwatchCore

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
}

@MainActor @Test func testRendersAMultiPagePDF() throws {
    // Enough events to force more than one page.
    let events = (0..<80).map { i in
        EventRecord(id: Int64(i), startedAt: iso("2026-07-21T23:00:00-05:00").addingTimeInterval(Double(i)*60),
                    durationSec: 5, peakDBFS: -25, meanDBFS: -32, bandLowHz: 20, bandHighHz: 120,
                    thresholdDBFS: -40, deviceUID: "D", clipPath: "/c\(i).flac")
    }
    let data = ReportData(rangeStart: iso("2026-07-01T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-31T00:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 2_000_000, gapSeconds: 3600, gapCount: 1),
                          dailyCounts: [DailyCount(day: "2026-07-21", count: 80)],
                          bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("report-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url)

    #expect(FileManager.default.fileExists(atPath: url.path))
    let doc = try #require(CGPDFDocument(url as CFURL))
    #expect(doc.numberOfPages >= 2)   // the event table alone spills past one page
}

@MainActor @Test func testEmptyReportStillRendersOnePage() throws {
    let data = ReportData(rangeStart: iso("2026-07-01T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-02T00:00:00-05:00"),
                          events: [], gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [], bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url)
    let doc = try #require(CGPDFDocument(url as CFURL))
    #expect(doc.numberOfPages >= 1)
}

// MARK: - Local-time rendering (defect fix)

@MainActor @Test func testEventTimesRenderInLocalTimeNotUTC() throws {
    // 2026-07-21T22:00:00-05:00 is 2026-07-22T03:00:00Z. A UTC render would
    // wrongly show this 10pm-local nighttime event as 3am the next day.
    let chicago = try #require(TimeZone(identifier: "America/Chicago"))
    let startedAt = iso("2026-07-21T22:00:00-05:00")
    let events = [
        EventRecord(id: 1, startedAt: startedAt, durationSec: 5, peakDBFS: -25, meanDBFS: -32,
                    bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D", clipPath: "/c0.flac")
    ]
    let data = ReportData(rangeStart: startedAt, rangeEnd: startedAt.addingTimeInterval(3600),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 3600, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [], bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("local-time-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url, timeZone: chicago)

    let doc = try #require(PDFDocument(url: url))
    let text = try #require(doc.string)

    // The local hour (10 PM) must appear, and the UTC hour (3 AM / the "Z"
    // ISO8601 form) must not — a landlord/council reader must see this as a
    // nighttime event, not an early-morning one.
    #expect(text.contains("10:00"))
    #expect(text.contains("PM"))
    #expect(!text.contains("03:00:00Z"))
    #expect(!text.contains("2026-07-22T03"))
}

// MARK: - Formatting helper unit tests (robust even if PDF text extraction is flaky)

@MainActor @Test func testFormattedHeaderUsesLocalTimeZone() {
    let chicago = TimeZone(identifier: "America/Chicago")!
    let date = iso("2026-07-21T22:00:00-05:00")
    let s = ReportRenderer.formattedHeader(date, timeZone: chicago)
    #expect(s.contains("10:00 PM"))
    #expect(s.contains("Jul 21, 2026"))
    #expect(!s.contains("03:00"))
}

@MainActor @Test func testFormattedRowUsesLocalTimeZone() {
    let chicago = TimeZone(identifier: "America/Chicago")!
    let date = iso("2026-07-21T22:00:00-05:00")
    let s = ReportRenderer.formattedRow(date, timeZone: chicago)
    #expect(s.contains("10:00:00 PM"))
    #expect(s.contains("Jul 21"))
    #expect(!s.contains("03:00"))
}

@MainActor @Test func testFormattedHeaderDiffersAcrossTimeZones() {
    let date = iso("2026-07-21T22:00:00-05:00") // instant is fixed regardless of zone
    let chicago = TimeZone(identifier: "America/Chicago")!
    let utc = TimeZone(identifier: "UTC")!
    let localString = ReportRenderer.formattedHeader(date, timeZone: chicago)
    let utcString = ReportRenderer.formattedHeader(date, timeZone: utc)
    #expect(localString != utcString)
    #expect(localString.contains("10:00 PM"))
    #expect(utcString.contains("3:00 AM"))
}

// MARK: - Coverage-gap wording (UX fix)

@MainActor @Test func testShortGapRendersSecondsNotZeroHours() throws {
    // A 4-second gap should read "4 s", not round away to "0.0 h".
    let data = ReportData(rangeStart: iso("2026-07-01T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-02T00:00:00-05:00"),
                          events: [], gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86396, gapSeconds: 4, gapCount: 1),
                          dailyCounts: [], bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gap-seconds-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url)

    let doc = try #require(PDFDocument(url: url))
    let text = try #require(doc.string)

    #expect(text.contains("4 s"))
    #expect(text.contains("gap"))
    #expect(!text.contains("0.0 h"))
}

@MainActor @Test func testZeroGapsRendersContinuousWording() throws {
    let data = ReportData(rangeStart: iso("2026-07-01T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-02T00:00:00-05:00"),
                          events: [], gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [], bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gap-none-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url)

    let doc = try #require(PDFDocument(url: url))
    let text = try #require(doc.string)

    #expect(text.contains("none"))
    #expect(text.contains("continuous"))
}

// MARK: - Event table layout (UX fix)

@MainActor @Test func testEventTableHeaderUsesHumanLabels() throws {
    let events = [
        EventRecord(id: 1, startedAt: iso("2026-07-21T22:00:00-05:00"), durationSec: 5.2, peakDBFS: -25.3,
                    meanDBFS: -32, bandLowHz: 1000, bandHighHz: 4000, thresholdDBFS: -40,
                    deviceUID: "D", clipPath: "/c0.flac")
    ]
    let data = ReportData(rangeStart: iso("2026-07-21T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-22T00:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [], bandLowHz: 1000, bandHighHz: 4000, thresholdDBFS: -40)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("table-header-\(UUID().uuidString).pdf")
    try ReportRenderer.renderPDF(data, to: url)

    let doc = try #require(PDFDocument(url: url))
    let text = try #require(doc.string)

    #expect(text.contains("Time"))
    #expect(text.contains("Peak dBFS"))
    #expect(text.contains("Duration"))
    #expect(text.contains("Band"))
    #expect(!text.contains("start_time"))
    #expect(!text.contains("dur(s)"))
}

// MARK: - Sample PDF for manual inspection (fixed path, left in place on purpose)

@MainActor @Test func testWritesSamplePDFForManualReview() throws {
    let chicago = try #require(TimeZone(identifier: "America/Chicago"))
    let events = (0..<5).map { i in
        EventRecord(id: Int64(i), startedAt: iso("2026-07-21T18:38:16-05:00").addingTimeInterval(Double(i) * 900),
                    durationSec: 5.2 + Double(i), peakDBFS: -25.3 - Double(i), meanDBFS: -32,
                    bandLowHz: 1000, bandHighHz: 4000, thresholdDBFS: -40, deviceUID: "D", clipPath: "/c\(i).flac")
    }
    let data = ReportData(rangeStart: iso("2026-07-20T00:00:00-05:00"),
                          rangeEnd: iso("2026-07-21T08:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 92160, gapSeconds: 4, gapCount: 1),
                          dailyCounts: [DailyCount(day: "2026-07-21", count: 5)],
                          bandLowHz: 1000, bandHighHz: 4000, thresholdDBFS: -40)
    let url = URL(fileURLWithPath: "/tmp/bw_report_check.pdf")
    try ReportRenderer.renderPDF(data, to: url, timeZone: chicago)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let doc = try #require(CGPDFDocument(url as CFURL))
    #expect(doc.numberOfPages >= 1)
}
