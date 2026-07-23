import Foundation
import Observation

/// Read-only view-model for the Review window. Opens the recording database
/// read-only, queries a date range, and closes — never holding the connection
/// open, so it never pins a WAL snapshot while recording continues.
@MainActor
@Observable
public final class ReviewModel {
    public var rangeStart: Date { didSet { if isReady { load() } } }
    public var rangeEnd: Date { didSet { if isReady { load() } } }
    public var selectedEventID: Int64?
    public var selectedDay: Date?

    public private(set) var events: [EventRecord] = []
    public private(set) var dailyCounts: [DailyCount] = []
    public private(set) var coverage: CoverageTotals?
    public private(set) var gaps: [GapRecord] = []
    public private(set) var spans: [SpanRecord] = []
    public private(set) var loadError: String?

    private let databaseURL: URL
    /// Guards `didSet` on `rangeStart`/`rangeEnd` from firing during `init`.
    /// `didSet` does not run for a property's own initial assignment in
    /// `init`, but it does fire for the *second* assignment below (setting
    /// `rangeStart` after `rangeEnd` is already set) — without this guard
    /// that second assignment would trigger a `load()` against a database
    /// that may not exist yet, before the caller ever asked for one.
    private var isReady = false

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        // default to the last 30 days
        self.rangeEnd = Date()
        self.rangeStart = Date().addingTimeInterval(-30 * 86400)
        self.isReady = true
    }

    public var selectedEvent: EventRecord? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    public func load() {
        do {
            let store = try EventStore(readOnlyURL: databaseURL)
            defer { store.close() }
            events = try store.events(from: rangeStart, to: rangeEnd)
            dailyCounts = try store.eventCountsByDay(from: rangeStart, to: rangeEnd)
            coverage = try store.coverageTotals(from: rangeStart, to: rangeEnd)
            gaps = try store.gaps(from: rangeStart, to: rangeEnd)
            spans = try store.spans(from: rangeStart, to: rangeEnd)
            loadError = nil
        } catch {
            events = []; dailyCounts = []; coverage = nil; gaps = []; spans = []
            loadError = "\(error)"
        }
    }

    /// Events belonging to the full calendar day OF `day`: local midnight
    /// (00:00) to the following midnight (24:00), half-open `[start, end)`.
    /// This matches the calendar heatmap, which already buckets by local
    /// calendar day (`substr(started_at,1,10)`), so a 2am event belongs to
    /// the same day on both surfaces.
    public func eventsForDay(of day: Date) -> [EventRecord] {
        let cal = Calendar.current
        let from = cal.startOfDay(for: day)
        let to = cal.date(byAdding: .day, value: 1, to: from)!
        return events.filter { $0.startedAt >= from && $0.startedAt < to }
    }

    /// The calendar state of a specific day, combining event counts and coverage.
    public func dayState(for day: Date, monitoredSecondsThatDay: Double) -> DayState {
        let key = Self.dayKey(day)
        let count = dailyCounts.first { $0.day == key }?.count ?? 0
        return DayClassifier.classify(day: Calendar.current.dateComponents([.year,.month,.day], from: day),
                                      eventCount: count,
                                      monitoredSecondsThatDay: monitoredSecondsThatDay)
    }

    private static let keyFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func dayKey(_ d: Date) -> String { keyFmt.string(from: d) }

    /// Monitored seconds for a day = time inside a monitoring span that day, minus
    /// in-span gap time. A day with no span returns 0 (provably not monitored),
    /// which `DayClassifier` reads as `.notMonitored` rather than a false `.quiet`.
    public func monitoredSeconds(on day: Date) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        var spanSecs = 0.0
        for s in spans {
            let a = max(s.startedAt, start), b = min(s.endedAt, end)
            spanSecs += max(b.timeIntervalSince(a), 0)
        }
        var gapSecs = 0.0
        for g in gaps {
            let a = max(g.startedAt, start), b = min(g.endedAt ?? end, end)
            gapSecs += max(b.timeIntervalSince(a), 0)
        }
        return max(spanSecs - gapSecs, 0)
    }

    public func selectDay(_ day: Date) {
        // filter selection to that day; view reads eventsForDay(of:)
        selectedDay = day
    }

    /// Assembles a `ReportData` snapshot from the model's currently-loaded
    /// state, for the Review window's "Export Evidence Bundle" action.
    /// `EventRecord`/`GapRecord`/`DailyCount`/`CoverageTotals` all have
    /// internal (not public) memberwise inits, so a `ReportData` cannot be
    /// constructed from the app target outside this package — this factory
    /// lives here, inside `BandwatchCore`, where those inits are accessible.
    /// Returns `nil` when there is nothing to export: no events and no
    /// coverage loaded (e.g. before the first `load()`, or after a failed
    /// one).
    public func currentReportData() -> ReportData? {
        guard !events.isEmpty || coverage != nil else { return nil }
        let cov = coverage ?? CoverageTotals(monitoredSeconds: 0, gapSeconds: 0, gapCount: 0)
        // coverage is now span-based — a positive record of monitoring — so it is
        // already honest and needs no clamp. A range with no spans reports zero
        // monitored seconds directly from coverageTotals.

        // Band/threshold header: honest only when every event agrees. An
        // empty-events export (a monitored-but-quiet period) must not fall
        // back to "0–0 Hz" — that reads as a real reading on a document
        // meant to prove a quiet period. A mixed-band range must not assert
        // a single setting that only the first event actually had.
        let hasBandInfo = !events.isEmpty
        var bandThresholdVaries = false
        var bandLowHz = 0.0, bandHighHz = 0.0, thresholdDBFS = 0.0
        if let first = events.first {
            bandLowHz = first.bandLowHz; bandHighHz = first.bandHighHz; thresholdDBFS = first.thresholdDBFS
            bandThresholdVaries = events.contains {
                $0.bandLowHz != first.bandLowHz || $0.bandHighHz != first.bandHighHz
                    || $0.thresholdDBFS != first.thresholdDBFS
            }
        }

        return ReportData(rangeStart: rangeStart, rangeEnd: rangeEnd,
                          events: events, gaps: gaps, coverage: cov, dailyCounts: dailyCounts,
                          bandLowHz: bandLowHz, bandHighHz: bandHighHz,
                          thresholdDBFS: thresholdDBFS,
                          hasBandInfo: hasBandInfo, bandThresholdVaries: bandThresholdVaries)
    }

}
