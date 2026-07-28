import Foundation
import SQLite3

/// SQLite is available from the system without any package dependency.
/// Verified: version 3.51.0 on this machine.

public enum GapReason: String, Sendable, CaseIterable {
    case deviceLost = "device_lost"
    case writeFailure = "write_failure"
    case diskFull = "disk_full"
    case shutdown = "shutdown"
    case captureStalled = "capture_stalled"
    case noSignal = "no_signal"
    /// Fallback for a reason string this build doesn't recognise — e.g. a row
    /// written by a future version with a new reason. Never inferred as
    /// `.shutdown`: that would misreport a possibly non-benign gap as a
    /// deliberate, benign one in a dataset whose purpose is proving coverage
    /// was continuous.
    case unknown = "unknown"
}

public struct EventRecord: Equatable, Sendable {
    public let id: Int64
    public let startedAt: Date
    public let durationSec: Double
    public let peakDBFS: Double
    public let meanDBFS: Double
    public let bandLowHz: Double
    public let bandHighHz: Double
    public let thresholdDBFS: Double
    public let deviceUID: String
    public let clipPath: String
}

public struct GapRecord: Equatable, Sendable {
    public let id: Int64
    public let startedAt: Date
    public let endedAt: Date?
    public let reason: GapReason
}

public struct SpanRecord: Equatable, Sendable {
    public let id: Int64
    public let startedAt: Date
    public let endedAt: Date
}

public enum EventStoreError: Error, Equatable {
    case couldNotOpen(String)
    case sqlFailed(String)
}

/// Number of events on a single calendar day, for the Review feature's
/// events-per-day chart. A day with zero events is simply absent from the
/// result rather than represented with `count == 0` — see
/// `EventStore.eventCountsByDay(from:to:)`.
public struct DailyCount: Equatable, Sendable {
    public let day: String    // yyyy-MM-dd, in the store's timezone
    public let count: Int
}

/// Coverage summary over a date range, for the Review feature's totals.
public struct CoverageTotals: Equatable, Sendable {
    public let monitoredSeconds: Double
    public let gapSeconds: Double
    public let gapCount: Int
}

/// The event log and the coverage-gap log.
///
/// Not thread-safe and not Sendable — used only from inside
/// `RecordingCoordinator`, which provides isolation.
///
/// Levels are stored raw (dBFS). A future SPL calibration is applied as a
/// display-time offset, never baked into stored values, so historical rows
/// become SPL-readable retroactively. Band and threshold are stored per event
/// so old rows stay interpretable after settings change.
public final class EventStore {
    private var db: OpaquePointer?

    // Not `static`: the formatter is timezone-pinned per instance (see
    // `init(url:timeZone:)`), so it can't be shared across instances that
    // might be configured with different zones. `EventStore` itself is
    // documented as not Sendable and used only from within a single actor's
    // isolation (RecordingCoordinator), so a non-Sendable stored property is
    // safe here.
    private let iso: ISO8601DateFormatter

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// - Parameter timeZone: The zone `started_at`/`ended_at` are rendered
    ///   in, with an explicit UTC offset (e.g. `-05:00`) rather than `Z`, so a
    ///   stored row reads consistently with the local-time-plus-offset
    ///   filenames `RecordingPaths` produces for the same instant. Defaults
    ///   to the host's current zone, like `RecordingPaths`; tests can pin a
    ///   zone instead of depending on the machine's setting.
    public init(url: URL, timeZone: TimeZone = .current) throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        self.iso = formatter

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw EventStoreError.couldNotOpen(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        // A Stop→Start cycle (including the fast churn of a device
        // disconnect/reconnect) briefly overlaps the previous coordinator's
        // still-open write connection with the new one's. WAL permits only one
        // writer at a time, so without a busy timeout that overlap surfaces as
        // an immediate "database is locked" error instead of a short wait for
        // the other writer's transaction to commit. Wait rather than fail.
        try exec("PRAGMA busy_timeout=5000;")
        try createEventsAndGapsSchema()
        try exec("""
        CREATE TABLE IF NOT EXISTS monitoring_spans (
            id         INTEGER PRIMARY KEY,
            started_at TEXT NOT NULL,
            ended_at   TEXT NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_spans_started_at ON monitoring_spans(started_at);")
    }

    /// Test-only: builds the pre-feature schema (events + gaps, NO monitoring_spans)
    /// to exercise the migration and read-only table-absence paths. Not used in production.
    init(legacyNoSpansURL url: URL, timeZone: TimeZone = .current) throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        self.iso = formatter
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw EventStoreError.couldNotOpen(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        // A Stop→Start cycle (including the fast churn of a device
        // disconnect/reconnect) briefly overlaps the previous coordinator's
        // still-open write connection with the new one's. WAL permits only one
        // writer at a time, so without a busy timeout that overlap surfaces as
        // an immediate "database is locked" error instead of a short wait for
        // the other writer's transaction to commit. Wait rather than fail.
        try exec("PRAGMA busy_timeout=5000;")
        try createEventsAndGapsSchema()
    }

    private func createEventsAndGapsSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS events (
            id             INTEGER PRIMARY KEY,
            started_at     TEXT NOT NULL,
            duration_sec   REAL NOT NULL,
            peak_dbfs      REAL NOT NULL,
            mean_dbfs      REAL NOT NULL,
            band_low_hz    REAL NOT NULL,
            band_high_hz   REAL NOT NULL,
            threshold_dbfs REAL NOT NULL,
            device_uid     TEXT NOT NULL,
            clip_path      TEXT NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_events_started_at ON events(started_at);")
        try exec("""
        CREATE TABLE IF NOT EXISTS gaps (
            id         INTEGER PRIMARY KEY,
            started_at TEXT NOT NULL,
            ended_at   TEXT,
            reason     TEXT NOT NULL
        );
        """)
    }

    /// Opens the database read-only for the Review feature, so it can
    /// inspect a database it is not recording into (and cannot mutate it
    /// even by accident). A read-only connection permits neither DDL nor
    /// PRAGMA, so unlike `init(url:timeZone:)` this runs no schema setup —
    /// the database must already exist, created by a prior writable
    /// `EventStore`, and already be in WAL mode (set by that writer), which
    /// is what allows this connection to read concurrently with it.
    public init(readOnlyURL url: URL, timeZone: TimeZone = .current) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        self.iso = formatter

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EventStoreError.couldNotOpen("no database at \(url.path)")
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw EventStoreError.couldNotOpen(msg)
        }
        // No CREATE TABLE, no PRAGMA — a read-only connection permits neither.
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: Events

    /// - Parameter clipPath: The location a clip would live at, not a
    ///   promise that a file exists there. A detection is real evidence even
    ///   when its clip is too short to write (see
    ///   `RecordingCoordinator.minimumReadableFrames`), so `RecordingCoordinator`
    ///   still inserts a row for it — `clip_path` records the expected
    ///   location so the gap is visible on inspection
    ///   (`FileManager.fileExists` returns false) rather than silently
    ///   implying audio that was never written. Callers reading this column
    ///   must check for the file's existence rather than assuming it.
    public func insertEvent(startedAt: Date, durationSec: Double, peakDBFS: Double,
                            meanDBFS: Double, band: FrequencyBand, thresholdDBFS: Double,
                            deviceUID: String, clipPath: String) throws -> Int64 {
        let sql = """
        INSERT INTO events (started_at, duration_sec, peak_dbfs, mean_dbfs,
                            band_low_hz, band_high_hz, threshold_dbfs, device_uid, clip_path)
        VALUES (?,?,?,?,?,?,?,?,?);
        """
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: startedAt), -1, Self.transient)
        sqlite3_bind_double(st, 2, durationSec)
        sqlite3_bind_double(st, 3, peakDBFS)
        sqlite3_bind_double(st, 4, meanDBFS)
        sqlite3_bind_double(st, 5, band.lowHz)
        sqlite3_bind_double(st, 6, band.highHz)
        sqlite3_bind_double(st, 7, thresholdDBFS)
        sqlite3_bind_text(st, 8, deviceUID, -1, Self.transient)
        sqlite3_bind_text(st, 9, clipPath, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
        return sqlite3_last_insert_rowid(db)
    }

    public func allEvents() throws -> [EventRecord] {
        try readEvents("SELECT id,started_at,duration_sec,peak_dbfs,mean_dbfs,band_low_hz,band_high_hz,threshold_dbfs,device_uid,clip_path FROM events ORDER BY started_at ASC;", bind: nil)
    }

    public func events(from: Date, to: Date) throws -> [EventRecord] {
        try readEvents("SELECT id,started_at,duration_sec,peak_dbfs,mean_dbfs,band_low_hz,band_high_hz,threshold_dbfs,device_uid,clip_path FROM events WHERE started_at >= ? AND started_at <= ? ORDER BY started_at ASC;") { st in
            sqlite3_bind_text(st, 1, self.iso.string(from: from), -1, Self.transient)
            sqlite3_bind_text(st, 2, self.iso.string(from: to), -1, Self.transient)
        }
    }

    // MARK: Gaps

    public func openGap(startedAt: Date, reason: GapReason) throws -> Int64 {
        let st = try prepare("INSERT INTO gaps (started_at, reason) VALUES (?,?);")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: startedAt), -1, Self.transient)
        sqlite3_bind_text(st, 2, reason.rawValue, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
        return sqlite3_last_insert_rowid(db)
    }

    public func closeGap(id: Int64, endedAt: Date) throws {
        let st = try prepare("UPDATE gaps SET ended_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: endedAt), -1, Self.transient)
        sqlite3_bind_int64(st, 2, id)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
    }

    public func openGaps() throws -> [GapRecord] {
        try readGaps("SELECT id,started_at,ended_at,reason FROM gaps WHERE ended_at IS NULL ORDER BY started_at ASC;")
    }

    public func allGaps() throws -> [GapRecord] {
        try readGaps("SELECT id,started_at,ended_at,reason FROM gaps ORDER BY started_at ASC;")
    }

    /// Resolves coverage gaps left OPEN by a crash in a PRIOR run — rows with a
    /// `started_at` before `cutoff` and no `ended_at`. Each is closed at the
    /// latest monitoring-span heartbeat at or after its start (the last instant
    /// the app is known to have been alive), or at its own `started_at` when no
    /// such span exists. Returns how many were resolved. Keeps each gap's
    /// original `reason` — the record of WHY coverage lapsed is preserved; only
    /// its missing end is filled in.
    ///
    /// `cutoff` MUST be this process's launch time. That is what prevents this
    /// from touching a gap the CURRENTLY-running app opened and will close
    /// itself — an in-progress device-disconnect gap, or one being finalized by
    /// a Stop→Start teardown racing a new coordinator's creation. Only rows that
    /// predate this launch can be orphans from a previous run.
    @discardableResult
    public func resolveStaleOpenGaps(before cutoff: Date) throws -> Int {
        let lastAlive = tableExists("monitoring_spans")
            ? "(SELECT MAX(ended_at) FROM monitoring_spans WHERE ended_at >= gaps.started_at)"
            : "NULL"
        let st = try prepare("""
        UPDATE gaps SET ended_at = COALESCE(\(lastAlive), gaps.started_at)
        WHERE ended_at IS NULL AND started_at < ?;
        """)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: cutoff), -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
        return Int(sqlite3_changes(db))
    }

    /// The earliest and latest timestamps of any recorded activity — events,
    /// gaps, or monitoring spans — or nil when the database holds none. Used to
    /// default the Review/report range to the period the data actually spans
    /// rather than an arbitrary window. Tolerant of a database predating the
    /// spans feature (opened read-only, no `monitoring_spans` table).
    public func dataExtent() throws -> (earliest: Date, latest: Date)? {
        var sources = [
            "SELECT started_at AS t FROM events",
            "SELECT started_at FROM gaps",
            "SELECT COALESCE(ended_at, started_at) FROM gaps",
        ]
        if tableExists("monitoring_spans") {
            sources.append("SELECT started_at FROM monitoring_spans")
            sources.append("SELECT ended_at FROM monitoring_spans")
        }
        let st = try prepare("SELECT MIN(t), MAX(t) FROM (\(sources.joined(separator: " UNION ALL ")));")
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW,
              sqlite3_column_type(st, 0) != SQLITE_NULL,
              sqlite3_column_type(st, 1) != SQLITE_NULL,
              let earliest = iso.date(from: String(cString: sqlite3_column_text(st, 0))),
              let latest = iso.date(from: String(cString: sqlite3_column_text(st, 1)))
        else { return nil }
        return (earliest, latest)
    }

    // MARK: Spans

    /// Opens a monitoring span. `ended_at` is set equal to `started_at` at open
    /// (never NULL) and rolled forward by `updateSpanEnd` — so a crash leaves the
    /// span finalized in place at its last heartbeat, never open and never "now".
    public func openSpan(startedAt: Date) throws -> Int64 {
        let st = try prepare("INSERT INTO monitoring_spans (started_at, ended_at) VALUES (?,?);")
        defer { sqlite3_finalize(st) }
        let ts = iso.string(from: startedAt)
        sqlite3_bind_text(st, 1, ts, -1, Self.transient)
        sqlite3_bind_text(st, 2, ts, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
        return sqlite3_last_insert_rowid(db)
    }

    /// Rolls (heartbeat) or finalizes (stop) a span's `ended_at`.
    public func updateSpanEnd(id: Int64, endedAt: Date) throws {
        let st = try prepare("UPDATE monitoring_spans SET ended_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: endedAt), -1, Self.transient)
        sqlite3_bind_int64(st, 2, id)
        guard sqlite3_step(st) == SQLITE_DONE else { throw sqlError() }
    }

    /// Spans overlapping `[from, to]`: started before `to` AND ended after `from`.
    /// Table-absence-tolerant: a database predating this feature (opened read-only,
    /// where CREATE TABLE is not permitted) has no monitoring_spans table, and this
    /// returns [] rather than throwing.
    public func spans(from: Date, to: Date) throws -> [SpanRecord] {
        guard tableExists("monitoring_spans") else { return [] }
        let st = try prepare("""
        SELECT id, started_at, ended_at FROM monitoring_spans
        WHERE started_at <= ? AND ended_at >= ?
        ORDER BY started_at ASC;
        """)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: to), -1, Self.transient)
        sqlite3_bind_text(st, 2, iso.string(from: from), -1, Self.transient)
        var out: [SpanRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(SpanRecord(
                id: sqlite3_column_int64(st, 0),
                startedAt: iso.date(from: String(cString: sqlite3_column_text(st, 1))) ?? .distantPast,
                endedAt: iso.date(from: String(cString: sqlite3_column_text(st, 2))) ?? .distantFuture))
        }
        return out
    }

    private func tableExists(_ name: String) -> Bool {
        guard let st = try? prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;")
        else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, name, -1, Self.transient)
        return sqlite3_step(st) == SQLITE_ROW
    }

    // MARK: Review aggregates

    /// Events grouped by calendar day, ascending. The calendar day is extracted
    /// via `substr(started_at, 1, 10)`, which reads the first 10 characters
    /// (`yyyy-MM-dd`) of the stored local-time ISO string, representing the day
    /// in this store's timezone (the offset baked into `started_at` by whichever
    /// timezone the writer used). A quiet day has no row at all, rather than
    /// a row with `count == 0` — callers filling a chart must treat absence
    /// as zero themselves.
    public func eventCountsByDay(from: Date, to: Date) throws -> [DailyCount] {
        let sql = """
        SELECT substr(started_at, 1, 10) AS day, COUNT(*) AS n
        FROM events WHERE started_at >= ? AND started_at <= ?
        GROUP BY day ORDER BY day ASC;
        """
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: from), -1, Self.transient)
        sqlite3_bind_text(st, 2, iso.string(from: to), -1, Self.transient)
        var out: [DailyCount] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(DailyCount(day: String(cString: sqlite3_column_text(st, 0)),
                                  count: Int(sqlite3_column_int(st, 1))))
        }
        return out
    }

    /// The wall-clock start time of the most recently started event, or nil
    /// when the events table is empty. Used to seed
    /// `MonitoringSession.lastEventAt` at monitoring start, so the "Last
    /// event" readout reflects real history across restarts rather than
    /// resetting to "none" every launch.
    public func latestEventStartedAt() throws -> Date? {
        let st = try prepare("SELECT MAX(started_at) FROM events;")
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL,
              let text = sqlite3_column_text(st, 0) else { return nil }
        return iso.date(from: String(cString: text))
    }

    public func eventCount(from: Date, to: Date) throws -> Int {
        let st = try prepare("SELECT COUNT(*) FROM events WHERE started_at >= ? AND started_at <= ?;")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, iso.string(from: from), -1, Self.transient)
        sqlite3_bind_text(st, 2, iso.string(from: to), -1, Self.transient)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    /// Gaps overlapping `[from, to]`: started before `to` AND (still open OR
    /// ended after `from`).
    public func gaps(from: Date, to: Date) throws -> [GapRecord] {
        return try readGaps("""
        SELECT id, started_at, ended_at, reason FROM gaps
        WHERE started_at <= ? AND (ended_at IS NULL OR ended_at >= ?)
        ORDER BY started_at ASC;
        """) { st in
            sqlite3_bind_text(st, 1, self.iso.string(from: to), -1, Self.transient)
            sqlite3_bind_text(st, 2, self.iso.string(from: from), -1, Self.transient)
        }
    }

    /// Monitored seconds over `[from, to]` = time inside a monitoring span, minus
    /// in-span gap time. Spans are the positive record of "the recorder was
    /// running"; gaps are interruptions within a run. A range with no span reports
    /// zero monitored seconds — the calendar/PDF no longer infer coverage from the
    /// mere absence of gap rows. Each span/gap is clamped to the range; a span
    /// contributes only its real [started_at, ended_at] seconds and is never
    /// extended to `to`, so coverage never overstates.
    public func coverageTotals(from: Date, to: Date) throws -> CoverageTotals {
        var spanSeconds = 0.0
        for s in try spans(from: from, to: to) {
            let start = max(s.startedAt, from)
            let end = min(s.endedAt, to)
            spanSeconds += max(end.timeIntervalSince(start), 0)
        }
        let overlappingGaps = try gaps(from: from, to: to)
        var gapSeconds = 0.0
        for g in overlappingGaps {
            let start = max(g.startedAt, from)
            let end = min(g.endedAt ?? to, to)
            gapSeconds += max(end.timeIntervalSince(start), 0)
        }
        return CoverageTotals(monitoredSeconds: max(spanSeconds - gapSeconds, 0),
                              gapSeconds: gapSeconds, gapCount: overlappingGaps.count)
    }

    // MARK: Private

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw EventStoreError.sqlFailed(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw sqlError() }
        return st
    }

    private func sqlError() -> EventStoreError {
        .sqlFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    private func readEvents(_ sql: String,
                            bind: ((OpaquePointer?) -> Void)? = nil) throws -> [EventRecord] {
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        bind?(st)
        var out: [EventRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(EventRecord(
                id: sqlite3_column_int64(st, 0),
                startedAt: iso.date(from: String(cString: sqlite3_column_text(st, 1))) ?? .distantPast,
                durationSec: sqlite3_column_double(st, 2),
                peakDBFS: sqlite3_column_double(st, 3),
                meanDBFS: sqlite3_column_double(st, 4),
                bandLowHz: sqlite3_column_double(st, 5),
                bandHighHz: sqlite3_column_double(st, 6),
                thresholdDBFS: sqlite3_column_double(st, 7),
                deviceUID: String(cString: sqlite3_column_text(st, 8)),
                clipPath: String(cString: sqlite3_column_text(st, 9))))
        }
        return out
    }

    private func readGaps(_ sql: String,
                          bind: ((OpaquePointer?) -> Void)? = nil) throws -> [GapRecord] {
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        bind?(st)
        var out: [GapRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let endedText = sqlite3_column_text(st, 2)
            out.append(GapRecord(
                id: sqlite3_column_int64(st, 0),
                startedAt: iso.date(from: String(cString: sqlite3_column_text(st, 1))) ?? .distantPast,
                endedAt: endedText.map { iso.date(from: String(cString: $0)) } ?? nil,
                reason: GapReason(rawValue: String(cString: sqlite3_column_text(st, 3))) ?? .unknown))
        }
        return out
    }
}
