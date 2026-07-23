import AppKit
import CoreGraphics
import Foundation

public struct ReportData: Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let events: [EventRecord]
    public let gaps: [GapRecord]
    public let coverage: CoverageTotals
    public let dailyCounts: [DailyCount]
    public let bandLowHz: Double
    public let bandHighHz: Double
    public let thresholdDBFS: Double
    /// False when `events` is empty — there is no band/threshold reading to
    /// report at all, and `bandLowHz`/`bandHighHz`/`thresholdDBFS` are
    /// meaningless sentinel zeros in that case, not a real "0–0 Hz" setting.
    public let hasBandInfo: Bool
    /// True when `events` contains more than one distinct band/threshold
    /// setting. `bandLowHz`/`bandHighHz`/`thresholdDBFS` then only reflect
    /// the first event and must not be presented as the single setting for
    /// the whole range — the per-event table is the honest source in that case.
    public let bandThresholdVaries: Bool
    /// Whether any included event's band overlaps the speech-intelligibility
    /// range, meaning its band-filtered clip could contain understandable
    /// conversation. Checked per-event so it's honest even when the band varied
    /// across the range.
    public var mayContainSpeech: Bool {
        events.contains { e in
            FrequencyBand(lowHz: e.bandLowHz, highHz: e.bandHighHz)?.overlapsSpeechRange ?? false
        }
    }

    /// Shared warning text for the PDF and the bundle README when
    /// `mayContainSpeech` is true.
    public static let speechWarning =
        "Note: the monitored band overlaps speech frequencies (~300 Hz–3.4 kHz), " +
        "so included clips may contain intelligible conversation. Review and share " +
        "this bundle accordingly."

    public init(rangeStart: Date, rangeEnd: Date, events: [EventRecord], gaps: [GapRecord],
                coverage: CoverageTotals, dailyCounts: [DailyCount],
                bandLowHz: Double, bandHighHz: Double, thresholdDBFS: Double,
                hasBandInfo: Bool = true, bandThresholdVaries: Bool = false) {
        self.rangeStart = rangeStart; self.rangeEnd = rangeEnd; self.events = events
        self.gaps = gaps; self.coverage = coverage; self.dailyCounts = dailyCounts
        self.bandLowHz = bandLowHz; self.bandHighHz = bandHighHz; self.thresholdDBFS = thresholdDBFS
        self.hasBandInfo = hasBandInfo; self.bandThresholdVaries = bandThresholdVaries
    }
}

@MainActor
public enum ReportRenderer {
    static let methodology = """
    Levels are dBFS (decibels relative to digital full scale), not calibrated \
    sound pressure level (SPL). The measurement is tone-referenced: a full-scale \
    tone reads 0 dBFS, approximately 3 dB above its true RMS. Audio is \
    band-filtered to the selected range. Figures are valid for relative \
    comparison, not as absolute SPL.
    """

    private static let pageW = 612.0, pageH = 792.0
    private static let margin = 54.0

    // Fixed event-table column x-offsets (from the left margin), so columns
    // line up regardless of proportional-font space widths. Time and Band
    // are left-aligned at their x; Duration and Peak dBFS are right-aligned
    // *to* their x (text drawn ending at that x).
    private static let colTimeX = margin
    private static let colDurationRightX = margin + 200
    private static let colPeakRightX = margin + 290
    private static let colBandX = margin + 360

    /// Human-readable "header" timestamp, e.g. "Jul 20, 2026  10:00 PM CDT".
    /// Uses a fixed POSIX locale so the format is stable regardless of the
    /// user's system locale, but renders in the *local* `timeZone` supplied
    /// by the caller (events are stored local-time; see M3 decision) rather
    /// than UTC — a UTC render of a 10pm event would misleadingly show as
    /// 3am the next day in a nighttime-noise report.
    static func formattedHeader(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, yyyy  h:mm a zzz"
        return f.string(from: date)
    }

    /// Compact per-row timestamp for the event table, e.g. "Jul 20  10:00:00 PM".
    /// Same timezone rules as `formattedHeader`; omits the zone abbreviation
    /// per-row since it is stated once in the report header.
    static func formattedRow(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d  h:mm:ss a"
        return f.string(from: date)
    }

    /// Adaptive-unit duration for the coverage-gap summary, e.g. "4 s",
    /// "4.2 min", "1.5 h" — a short gap should read as seconds, not round
    /// away to "0.0 h" and look like it never happened.
    static func formattedDuration(seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds.rounded())) s"
        } else if seconds < 3600 {
            return String(format: "%.1f min", seconds / 60)
        } else {
            return String(format: "%.1f h", seconds / 3600)
        }
    }

    /// Self-explanatory coverage-gap line, e.g.:
    ///   "Coverage gaps: none — monitoring was continuous over the covered period."
    ///   "Coverage gaps: 1 gap (period not monitored), totaling 4 s."
    ///   "Coverage gaps: 3 gaps (periods not monitored), totaling 1.5 h."
    static func coverageGapLine(gapCount: Int, gapSeconds: Double) -> String {
        if gapCount == 0 {
            return "Coverage gaps: none — monitoring was continuous over the covered period."
        } else if gapCount == 1 {
            return "Coverage gaps: 1 gap (period not monitored), totaling \(formattedDuration(seconds: gapSeconds))."
        } else {
            return "Coverage gaps: \(gapCount) gaps (periods not monitored), totaling \(formattedDuration(seconds: gapSeconds))."
        }
    }

    public static func renderPDF(_ data: ReportData, to url: URL, timeZone: TimeZone = .current) throws {
        var media = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw NSError(domain: "ReportRenderer", code: 1)
        }

        var page = 0
        var y = 0.0
        func newPage() {
            if page > 0 { footer(ctx, page: page) ; ctx.endPDFPage() }
            ctx.beginPDFPage(nil); page += 1; y = pageH - margin
        }
        func space(_ needed: Double) { if y - needed < margin + 24 { newPage() } }
        func text(_ s: String, size: CGFloat, bold: Bool = false, gap: Double = 6) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
            let bounds = attr.boundingRect(with: CGSize(width: pageW - 2*margin, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            space(bounds.height)
            let g = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = g
            attr.draw(with: CGRect(x: margin, y: y - bounds.height, width: pageW - 2*margin, height: bounds.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            y -= bounds.height + gap
        }
        // Draws one event-table row (or the header row) at the fixed column
        // x-positions, on a single baseline — no space-padding involved, so
        // columns stay aligned regardless of each cell's text width. A row
        // never splits across a page break: `space()` is checked once for
        // the whole row before anything is drawn.
        func tableRow(timeText: String, durationText: String, peakText: String, bandText: String, bold: Bool) {
            let size: CGFloat = 9
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            let cellMaxWidth = pageW - margin - colTimeX
            func attr(_ s: String) -> NSAttributedString {
                NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
            }
            func width(_ a: NSAttributedString) -> Double {
                a.boundingRect(with: CGSize(width: cellMaxWidth, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).width
            }
            let timeAttr = attr(timeText), durAttr = attr(durationText)
            let peakAttr = attr(peakText), bandAttr = attr(bandText)
            let rowHeight = timeAttr.boundingRect(with: CGSize(width: cellMaxWidth, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            space(rowHeight)
            let g = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = g
            let rowY = y - rowHeight
            func draw(_ a: NSAttributedString, leftX: Double? = nil, rightEdgeX: Double? = nil) {
                let w = width(a)
                let x = rightEdgeX.map { $0 - w } ?? leftX!
                a.draw(with: CGRect(x: x, y: rowY, width: w + 1, height: rowHeight),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            draw(timeAttr, leftX: colTimeX)
            draw(durAttr, rightEdgeX: colDurationRightX)
            draw(peakAttr, rightEdgeX: colPeakRightX)
            draw(bandAttr, leftX: colBandX)
            y -= rowHeight + 2
        }

        newPage()
        // Header
        text("Bandwatch — Noise Evidence Report", size: 20, bold: true)
        text("Range: \(formattedHeader(data.rangeStart, timeZone: timeZone))  to  \(formattedHeader(data.rangeEnd, timeZone: timeZone))", size: 10)
        let bandLine: String
        if !data.hasBandInfo {
            bandLine = "Band: —    Threshold: —"
        } else if data.bandThresholdVaries {
            bandLine = "Band: varies (see table)    Threshold: varies (see table)"
        } else {
            bandLine = "Band: \(Int(data.bandLowHz))–\(Int(data.bandHighHz)) Hz    Threshold: \(String(format: "%.1f", data.thresholdDBFS)) dBFS"
        }
        text(bandLine, size: 10)
        text("Generated: \(formattedHeader(nowStamp(), timeZone: timeZone))", size: 9, gap: 16)

        // Summary
        text("Summary", size: 14, bold: true)
        text("Total events: \(data.events.count)", size: 11)
        let hoursMon = data.coverage.monitoredSeconds / 3600
        text("Monitored: \(String(format: "%.1f", hoursMon)) h", size: 11, gap: 2)
        text(coverageGapLine(gapCount: data.coverage.gapCount, gapSeconds: data.coverage.gapSeconds), size: 11, gap: 16)

        // Event table — fixed column x-positions so a proportional font can't
        // misalign space-padded columns. Numeric columns are right-aligned so
        // decimals line up; Time and Band are left-aligned.
        text("Events", size: 14, bold: true)
        tableRow(timeText: "Time", durationText: "Duration (s)", peakText: "Peak dBFS", bandText: "Band", bold: true)
        for e in data.events {
            tableRow(timeText: formattedRow(e.startedAt, timeZone: timeZone),
                     durationText: String(format: "%.1f", e.durationSec),
                     peakText: String(format: "%.1f", e.peakDBFS),
                     bandText: "\(Int(e.bandLowHz))–\(Int(e.bandHighHz)) Hz",
                     bold: false)
        }

        // Methodology — always on its own fresh block
        y -= 12
        text("Methodology & limitations", size: 12, bold: true)
        text(methodology, size: 9)
        if data.mayContainSpeech {
            y -= 4
            text(ReportData.speechWarning, size: 9, bold: true)
        }

        footer(ctx, page: page)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func footer(_ ctx: CGContext, page: Int) {
        let s = NSAttributedString(string: "Bandwatch evidence report — page \(page)",
                                   attributes: [.font: NSFont.systemFont(ofSize: 8),
                                                .foregroundColor: NSColor.gray])
        let g = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = g
        s.draw(at: CGPoint(x: margin, y: 30))
    }

    // Injectable-free timestamp helper (Date() is disallowed in workflow scripts,
    // but this is app code, not a workflow — Date() is fine here).
    private static func nowStamp() -> Date { Date() }
}
