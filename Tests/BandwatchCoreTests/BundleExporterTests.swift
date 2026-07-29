import Testing
import Foundation
@testable import BandwatchCore

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)!
}

@MainActor @Test func testBundleContainsReportCSVsAndPresentClipsOnly() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bwbundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // one clip exists, one is missing (its file was never on disk)
    let clipA = tmp.appendingPathComponent("a.flac")
    try Data([1,2,3]).write(to: clipA)
    let events = [
        EventRecord(id: 1, startedAt: iso("2026-07-21T23:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                    meanDBFS: -28, bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D",
                    clipPath: clipA.path),
        EventRecord(id: 2, startedAt: iso("2026-07-21T23:10:00-05:00"), durationSec: 5, peakDBFS: -20,
                    meanDBFS: -28, bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D",
                    clipPath: tmp.appendingPathComponent("gone.flac").path)
    ]
    let data = ReportData(rangeStart: iso("2026-07-21T00:00:00-05:00"), rangeEnd: iso("2026-07-22T00:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [DailyCount(day: "2026-07-21", count: 2)],
                          bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let zip = tmp.appendingPathComponent("evidence.zip")
    let summary = try BundleExporter.export(data, to: zip, workDir: tmp.appendingPathComponent("work"))

    #expect(summary.clipsIncluded == 1)
    #expect(summary.clipsMissing == 1)
    #expect(FileManager.default.fileExists(atPath: zip.path))

    // unzip and inspect
    let out = tmp.appendingPathComponent("unzipped")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", zip.path, out.path]; try p.run(); p.waitUntilExit()
    let files = try FileManager.default.subpathsOfDirectory(atPath: out.path)
    #expect(files.contains { $0.hasSuffix("report.pdf") })
    #expect(files.contains { $0.hasSuffix("events.csv") })
    #expect(files.contains { $0.hasSuffix("gaps.csv") })
    #expect(files.contains { $0.hasSuffix("README.txt") })
    #expect(files.contains { $0.hasSuffix("a.flac") })
    #expect(files.contains { $0.hasSuffix("gone.flac") } == false)   // missing clip absent

    // When a clip IS genuinely missing, the bundle discloses it plainly as
    // "missing" (never "expired" — Bandwatch does not expire evidence).
    let readmeRel = try #require(files.first { $0.hasSuffix("README.txt") })
    let readmeText = try String(contentsOf: out.appendingPathComponent(readmeRel), encoding: .utf8)
    #expect(readmeText.contains("Clips included: 1"))
    #expect(readmeText.contains("Clips missing: 1"))
    #expect(readmeText.lowercased().contains("expired") == false)
    #expect(readmeText.lowercased().contains("never deletes or expires"))
}

@MainActor @Test func testSameBasenameClipsFromDifferentDirsBothIncluded() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bwbundle-\(UUID().uuidString)")
    let dirA = tmp.appendingPathComponent("dirA")
    let dirB = tmp.appendingPathComponent("dirB")
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
    // two clips with the SAME basename in different directories
    let clipA = dirA.appendingPathComponent("clip.flac")
    let clipB = dirB.appendingPathComponent("clip.flac")
    try Data([1,2,3]).write(to: clipA)
    try Data([4,5,6]).write(to: clipB)
    let events = [
        EventRecord(id: 1, startedAt: iso("2026-07-21T23:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                    meanDBFS: -28, bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D",
                    clipPath: clipA.path),
        EventRecord(id: 2, startedAt: iso("2026-07-21T23:10:00-05:00"), durationSec: 5, peakDBFS: -20,
                    meanDBFS: -28, bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D",
                    clipPath: clipB.path)
    ]
    let data = ReportData(rangeStart: iso("2026-07-21T00:00:00-05:00"), rangeEnd: iso("2026-07-22T00:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [DailyCount(day: "2026-07-21", count: 2)],
                          bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let zip = tmp.appendingPathComponent("evidence.zip")
    let summary = try BundleExporter.export(data, to: zip, workDir: tmp.appendingPathComponent("work"))

    #expect(summary.clipsIncluded == 2)
    #expect(summary.clipsMissing == 0)

    let out = tmp.appendingPathComponent("unzipped")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", zip.path, out.path]; try p.run(); p.waitUntilExit()
    let files = try FileManager.default.subpathsOfDirectory(atPath: out.path)
    let clipFiles = files.filter { $0.contains("clips/") && $0.hasSuffix(".flac") }
    #expect(clipFiles.count == 2)   // both distinct-named copies present, none clobbered

    // Healthy export (nothing missing): the summary omits the missing line
    // entirely — no "missing" count and no "expired" wording on the bundle.
    let readmeRel = try #require(files.first { $0.hasSuffix("README.txt") })
    let readmeText = try String(contentsOf: out.appendingPathComponent(readmeRel), encoding: .utf8)
    #expect(readmeText.contains("Clips included: 2"))
    #expect(readmeText.contains("Clips missing") == false)
    #expect(readmeText.lowercased().contains("expired") == false)
}

@MainActor @Test func testWorkingFolderRemovedAfterSuccessfulExport() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bwbundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let clipA = tmp.appendingPathComponent("a.flac")
    try Data([1,2,3]).write(to: clipA)
    let events = [
        EventRecord(id: 1, startedAt: iso("2026-07-21T23:00:00-05:00"), durationSec: 5, peakDBFS: -20,
                    meanDBFS: -28, bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40, deviceUID: "D",
                    clipPath: clipA.path)
    ]
    let data = ReportData(rangeStart: iso("2026-07-21T00:00:00-05:00"), rangeEnd: iso("2026-07-22T00:00:00-05:00"),
                          events: events, gaps: [],
                          coverage: CoverageTotals(monitoredSeconds: 86400, gapSeconds: 0, gapCount: 0),
                          dailyCounts: [DailyCount(day: "2026-07-21", count: 1)],
                          bandLowHz: 20, bandHighHz: 120, thresholdDBFS: -40)
    let zip = tmp.appendingPathComponent("evidence.zip")
    let workDir = tmp.appendingPathComponent("work")
    _ = try BundleExporter.export(data, to: zip, workDir: workDir)

    #expect(FileManager.default.fileExists(atPath: zip.path))
    // the assembled working folder (with evidence audio) must not remain on disk
    let leftover = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
    #expect(leftover.isEmpty)
}
