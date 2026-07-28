import Foundation

public struct RecordingStatus: Equatable, Sendable {
    public let isRecording: Bool
    public let currentSegment: String?
    public let eventsWritten: Int
    public let lastError: String?
    public let freeBytes: Int64?

    /// Archive segments (and the frames inside them) that `SegmentWriter`
    /// discarded because they never reached `SegmentWriter.minimumReadableFrames`
    /// and so could not finalize into a readable FLAC stream. Mirrors
    /// `SegmentWriter.discardedStubCount` / `discardedFrames`.
    ///
    /// Surfaced here rather than as a `gaps` row: `SegmentWriter` only
    /// reports aggregate counts, not the wall-clock bounds of each discarded
    /// stub, so there is no honest way to construct a dated gap for it —
    /// inventing timestamps would itself be a fabrication in a database whose
    /// entire purpose is being trustworthy. The counts are still real
    /// information the operator needs, so they ride along on `status()`
    /// instead of vanishing. (Contrast with `writeEventClip`'s too-short-clip
    /// case below, where the caller supplies exact start/end timestamps, so a
    /// real gap row can be logged honestly.)
    public let discardedStubCount: Int
    public let discardedFrames: Int

    /// Gaps still open (`ended_at IS NULL`) as measured once, at `init`, via
    /// `EventStore.openGaps()`. A gap left open by a crash in a previous
    /// process stays open forever unless something closes it, and it is never
    /// auto-closed here: this coordinator does not know when the interval
    /// actually ended, and inventing an end time would be a fabrication in a
    /// database whose entire purpose is being trustworthy. Surfacing the
    /// count is the honest action — it tells an operator or a future
    /// `RecordingCoordinator` that some past interval's coverage is still
    /// unaccounted for.
    public let staleOpenGaps: Int

    /// Cumulative counts of what `runRetention` has actually deleted over
    /// this coordinator's lifetime. Exists so a retention loop that is
    /// silently failing (e.g. every delete throwing) is visible as "0 and
    /// not climbing" rather than assumed to be working just because it ran.
    public let archiveFilesDeleted: Int
    public let eventClipsDeleted: Int

    /// Increments on every write failure (archive append, event clip write,
    /// or event-row insert) and resets to zero on the next successful write.
    /// `isRecording == true` only means a session is active, not that writes
    /// are succeeding — a full disk keeps `isRecording` true while every
    /// write fails. Unlike `lastError`, which any later message (including
    /// an unrelated one) overwrites, this is monotonic health information a
    /// UI can trust at a glance.
    public let consecutiveWriteFailures: Int

    /// Windows of filtered archive audio dropped because the bounded
    /// archive-delivery stream's buffer was full (a stalled disk) --
    /// mirrors `discardedStubCount`/`discardedFrames` above in being real,
    /// lost coverage that must be visible rather than silently counted and
    /// never read. Tracked session-side (in `MonitoringSession`, on the
    /// synchronous analysis path where the drop actually happens, before
    /// any audio would reach this actor) and merged into the status this
    /// coordinator reports -- see `MonitoringSession`'s status-polling task
    /// and `withDroppedArchiveWindowCount(_:)` below. Each drop also opens
    /// an `.archiveWindowDropped` gap (`RecordingCoordinator.noteArchiveWindowDropped`)
    /// so the discontinuity is recorded in the database, not just counted
    /// here.
    public let droppedArchiveWindowCount: Int

    public init(isRecording: Bool,
                currentSegment: String?,
                eventsWritten: Int,
                lastError: String?,
                freeBytes: Int64?,
                discardedStubCount: Int = 0,
                discardedFrames: Int = 0,
                staleOpenGaps: Int = 0,
                archiveFilesDeleted: Int = 0,
                eventClipsDeleted: Int = 0,
                consecutiveWriteFailures: Int = 0,
                droppedArchiveWindowCount: Int = 0) {
        self.isRecording = isRecording
        self.currentSegment = currentSegment
        self.eventsWritten = eventsWritten
        self.lastError = lastError
        self.freeBytes = freeBytes
        self.discardedStubCount = discardedStubCount
        self.discardedFrames = discardedFrames
        self.staleOpenGaps = staleOpenGaps
        self.archiveFilesDeleted = archiveFilesDeleted
        self.eventClipsDeleted = eventClipsDeleted
        self.consecutiveWriteFailures = consecutiveWriteFailures
        self.droppedArchiveWindowCount = droppedArchiveWindowCount
    }

    /// Returns a copy with `droppedArchiveWindowCount` replaced. See that
    /// property's doc comment for why this is merged in by the caller
    /// (`MonitoringSession`) rather than tracked inside this struct's own
    /// producer, `RecordingCoordinator.status()`.
    public func withDroppedArchiveWindowCount(_ count: Int) -> RecordingStatus {
        RecordingStatus(isRecording: isRecording, currentSegment: currentSegment,
                        eventsWritten: eventsWritten, lastError: lastError, freeBytes: freeBytes,
                        discardedStubCount: discardedStubCount, discardedFrames: discardedFrames,
                        staleOpenGaps: staleOpenGaps, archiveFilesDeleted: archiveFilesDeleted,
                        eventClipsDeleted: eventClipsDeleted,
                        consecutiveWriteFailures: consecutiveWriteFailures,
                        droppedArchiveWindowCount: count)
    }
}

/// Owns every file handle and the database. All disk I/O in the application
/// happens inside this actor.
///
/// Analysis stays on the main actor and hands audio across as `[Float]`,
/// which is `Sendable`. `AVAudioFile` (via `FLACWriter`/`SegmentWriter`) and
/// `EventStore` are not `Sendable` and never leave this actor.
///
/// Write errors are deliberately NOT thrown back to the caller: a failed
/// write must never stop analysis or capture. Instead a gap row is recorded
/// — `.diskFull` or `.writeFailure` depending on cause — and the message
/// surfaces through `status()`. That is what makes "we recorded all night" a
/// verifiable claim rather than an assumption: every interval that was not
/// recorded has a row explaining why.
public actor RecordingCoordinator {
    private let paths: RecordingPaths
    private let sampleRate: Double
    private let segments: SegmentWriter
    private let storage: StorageManager

    private let store: EventStore

    private var recording = false
    private var deviceUID = ""
    private var eventsWritten = 0
    private var lastError: String?

    /// At most one open gap per `GapReason`. A persistent condition (e.g. a
    /// full disk failing every append) calls `openGap` repeatedly — often
    /// many times a second — and must not insert a new row per call: that is
    /// unbounded growth in both the database and this dictionary. The
    /// existing open row already covers the ongoing condition, so a repeat
    /// call for a reason that is already open is a no-op.
    private var openGapIDsByReason: [GapReason: Int64] = [:]

    /// The id of the span this session opened, nil when not recording. Rolled by
    /// `heartbeatSpan` and finalized in `stop()`. Only one span is open per session.
    private var currentSpanID: Int64?

    private var lastReportedDiscardedStubCount = 0
    private var archiveFilesDeleted = 0
    private var eventClipsDeleted = 0
    private var consecutiveWriteFailures = 0

    /// Gaps discovered still open at `init`, before this session opens or
    /// closes anything. See `RecordingStatus.staleOpenGaps`.
    private let staleOpenGaps: Int

    public init(paths: RecordingPaths,
                sampleRate: Double,
                policy: RetentionPolicy = RetentionPolicy(),
                segmentDuration: TimeInterval = SegmentWriter.defaultSegmentDuration,
                resolveGapsOpenedBefore: Date = .distantPast) throws {
        self.paths = paths
        self.sampleRate = sampleRate
        self.segments = SegmentWriter(paths: paths, sampleRate: sampleRate,
                                      segmentDuration: segmentDuration)
        self.storage = StorageManager(paths: paths, policy: policy)
        self.store = try EventStore(url: paths.databaseURL)
        // Close any gaps a PRIOR run left open (a crash orphans them with no end
        // time), at the last instant that run was known alive, so the coverage
        // record is complete instead of nagging with an unresolvable banner.
        // Bounded to gaps predating this process's launch so it can never touch
        // a gap the current session is managing. Default `.distantPast` resolves
        // nothing (backward-compatible for callers that don't pass a cutoff).
        _ = try? self.store.resolveStaleOpenGaps(before: resolveGapsOpenedBefore)
        self.staleOpenGaps = (try? self.store.openGaps().count) ?? 0
    }

    public func start(deviceUID: String, at date: Date = Date()) {
        guard !recording else { return }
        self.deviceUID = deviceUID
        lastError = nil
        recording = true
        do {
            currentSpanID = try store.openSpan(startedAt: date)
        } catch {
            lastError = "span open failed: \(error)"
        }
    }

    /// Testing seam: `start(deviceUID:)` uses `Date()` internally for the span
    /// open, which deterministic tests can't pin. Mirrors the actor's other
    /// testing seams.
    func startForTesting(deviceUID: String, at date: Date) {
        start(deviceUID: deviceUID, at: date)
    }

    /// Rolls the current monitoring span's `ended_at` forward to `date`, so the
    /// span is always closed-through its last heartbeat. Driven by the session's
    /// status-poll task every 30 s. A no-op when no span is open (e.g. a poll that
    /// races `stop()`), mirroring `closeGap`'s guard.
    public func heartbeatSpan(at date: Date) {
        guard let id = currentSpanID else { return }
        do {
            try store.updateSpanEnd(id: id, endedAt: date)
        } catch {
            lastError = "span heartbeat failed: \(error)"
        }
    }

    /// Stops the current recording session: closes the in-progress archive
    /// segment and any open gaps, but deliberately leaves the database open.
    /// A Stop→Start cycle is a normal, expected UI action within one running
    /// process, and must not silently disable all future event/gap logging —
    /// only `shutdown()` (final teardown) closes the store. Idempotent: a
    /// second call, or a call with no prior `start()`, is a no-op.
    public func stop(at date: Date = Date()) {
        guard recording else { return }
        segments.closeCurrent()
        noteDiscardedStubsIfChanged()
        closeOpenGaps(at: date)
        if let id = currentSpanID {
            do { try store.updateSpanEnd(id: id, endedAt: date) }
            catch { lastError = "span finalize failed: \(error)" }
            currentSpanID = nil
        }
        recording = false
    }

    /// Final teardown: stops any in-progress session (closing the segment
    /// and any open gaps first, preserving the existing ordering guarantee)
    /// and then closes the database. The coordinator must not be used again
    /// afterwards.
    ///
    /// This is the *only* way the database gets closed — callers are
    /// expected to call it when they are done with a coordinator. There is
    /// deliberately no `deinit` that does this for you. A `deinit` runs
    /// outside actor isolation (it cannot be `async`), so making it close
    /// `store` would require marking `store` unsafe to touch from outside
    /// the actor's isolation — reopening the exact escape hatch this type
    /// was fixed to remove. Every non-isolated context would then be able to
    /// reach a non-`Sendable` SQLite handle without going through the actor.
    /// That isolation guarantee — that `store` can only ever be touched from
    /// inside this actor — is the entire reason this type exists, and it is
    /// worth more than automatic cleanup.
    ///
    /// Skipping `shutdown()` (e.g. dropping a coordinator without calling
    /// it) leaks the open database handle until the process exits, but loses
    /// no data: `EventStore` runs SQLite in WAL mode, which is crash-safe —
    /// every committed transaction is durable on disk whether or not the
    /// handle is ever explicitly closed. The OS reclaims the leaked handle
    /// at process exit.
    public func shutdown() {
        stop()
        store.close()
    }

    public func appendArchive(_ samples: [Float], wallClock: Date) {
        guard recording else { return }
        do {
            try segments.append(samples, wallClock: wallClock)
            noteDiscardedStubsIfChanged()
            recordWriteSuccess()
        } catch {
            recordWriteFailure(error, at: wallClock)
        }
    }

    /// Writes one event clip and logs its metadata row.
    ///
    /// A clip whose frame count is below `SegmentWriter.minimumReadableFrames`
    /// is never written to disk: a FLAC stream that short cannot finalize
    /// into anything openable (verified in `SegmentWriterTests` /
    /// `FLACWriterTests`), so writing it would leave an unopenable file on
    /// disk that the database claims is a recording — worse than not writing
    /// it at all. The detection itself is still real evidence (peak/mean
    /// level, duration, band, threshold), so the event row is still inserted
    /// and counted; `clipPath` records where a clip would have lived so the
    /// missing audio is visible on inspection (`FileManager.fileExists` on it
    /// returns false) rather than silently implied to exist. A `.writeFailure`
    /// gap spanning the event's own start/duration is also logged, because we
    /// know its exact bounds here (unlike the archive-stub case above) and it
    /// is exactly the situation gaps exist to record: an interval with no
    /// readable recorded audio.
    ///
    /// - Parameters:
    ///   - eventStartWallClock: When the NOISE itself began — the moment the
    ///     detector's candidate first crossed the trigger. This is what goes
    ///     in the database row (`insertEvent(startedAt:)` and the completed-
    ///     interval gap bounds on the short-clip path): the row's whole
    ///     purpose is to be honest evidence of when the noise happened, and
    ///     that is this value, not the clip's.
    ///   - clipStartWallClock: When the recorded AUDIO in the clip begins —
    ///     `eventStartWallClock` minus the pre-roll. This is what names the
    ///     file (`paths.eventClipURL(startingAt:)`) since the filename must
    ///     match the first sample actually in the file. The two are
    ///     deliberately distinct parameters: collapsing them back into one
    ///     value silently falsifies every event row by exactly the pre-roll.
    public func writeEventClip(samples: [Float],
                               event: DetectedEvent,
                               eventStartWallClock: Date,
                               clipStartWallClock: Date,
                               band: FrequencyBand,
                               thresholdDBFS: Double) {
        guard recording else {
            // An event detected while not recording is still a detection —
            // it must not vanish with no trace. There's no live session to
            // insert an event ROW against (no deviceUID, no open-session
            // semantics), but the interval itself is fully known
            // (eventStartWallClock + duration), so unlike the archive-stub
            // case above, a real gap CAN be logged honestly here -- e.g. a
            // caller that raced this actor's own `stop()` (which flips
            // `recording` false) between assembling a clip and awaiting
            // this call. Without it, that interval would have no
            // explanation anywhere in the database.
            lastError = "event dropped: not recording (start=\(eventStartWallClock), " +
                "duration=\(event.duration)s)"
            logCompletedInterval(reason: .writeFailure, start: eventStartWallClock,
                                 end: eventStartWallClock.addingTimeInterval(event.duration))
            return
        }
        let url = paths.eventClipURL(startingAt: clipStartWallClock)

        guard samples.count >= SegmentWriter.minimumReadableFrames else {
            lastError = "event clip too short to write (\(samples.count) frames < " +
                "\(SegmentWriter.minimumReadableFrames)): \(url.lastPathComponent)"
            insertEventRow(event: event, startWallClock: eventStartWallClock, band: band,
                          thresholdDBFS: thresholdDBFS, clipPath: url.path)
            logCompletedInterval(reason: .writeFailure, start: eventStartWallClock,
                                 end: eventStartWallClock.addingTimeInterval(event.duration))
            return
        }

        do {
            let w = try FLACWriter(url: url, sampleRate: sampleRate)
            try w.append(samples)
            w.close()   // must close before the row claims the file exists
            insertEventRow(event: event, startWallClock: eventStartWallClock, band: band,
                          thresholdDBFS: thresholdDBFS, clipPath: url.path)
        } catch {
            recordWriteFailure(error, at: eventStartWallClock)
        }
    }

    /// Records that `MonitoringSession` had to drop one window of filtered
    /// archive audio because its bounded delivery stream's buffer was full
    /// (a stalled disk) -- see `RecordingStatus.droppedArchiveWindowCount`.
    /// A dropped window means the NEXT window successfully delivered will
    /// be spliced onto the archive file as if it were continuous, which it
    /// is not, so this opens an `.archiveWindowDropped` gap recording that
    /// the discontinuity happened, even though (unlike `writeEventClip`'s
    /// short-clip case) the exact start/end of the missing audio is not
    /// known here -- only that a drop occurred at `date`. Like
    /// `.writeFailure`, this is left open (not immediately closed) because
    /// a stall is an ongoing condition, not a bounded interval with a known
    /// end; `stop()`/`shutdown()` closes it along with every other
    /// still-open gap once the session actually ends. Repeat drops during
    /// one stall dedupe to the single already-open row via the usual
    /// per-reason mechanism in `openGap`, so a sustained stall does not
    /// grow the gaps table once per dropped window.
    public func noteArchiveWindowDropped(at date: Date) {
        openGap(reason: .archiveWindowDropped, at: date)
    }

    /// Opens a gap for `reason`, unless one is already open for that same
    /// reason. A persistent condition (full disk, lost device) re-triggers
    /// this call repeatedly — the existing open row already covers the
    /// ongoing interval, so a repeat call is a no-op rather than a new row.
    public func openGap(reason: GapReason, at date: Date) {
        guard openGapIDsByReason[reason] == nil else { return }
        do {
            let id = try store.openGap(startedAt: date, reason: reason)
            openGapIDsByReason[reason] = id
        } catch {
            lastError = "gap log failed: \(error)"
        }
    }

    /// Closes only the open gap for `reason`, leaving every other reason's
    /// open gap (if any) untouched. This is what a recovery path must use
    /// when the session keeps running afterward: e.g. `.noSignal` clearing
    /// while a genuinely still-open `.writeFailure` gap is unrelated and
    /// must not be reported as having ended just because a DIFFERENT
    /// condition resolved. A no-op if `reason` has no open gap.
    ///
    /// Contrast with `closeOpenGaps`, which closes every open gap
    /// indiscriminately and is reserved for `stop()`, where the whole
    /// session — and every open condition along with it — is genuinely
    /// ending, so closing all of them at once is honest.
    public func closeGap(reason: GapReason, at date: Date) {
        guard let id = openGapIDsByReason[reason] else { return }
        do {
            try store.closeGap(id: id, endedAt: date)
            openGapIDsByReason[reason] = nil
        } catch {
            lastError = "gap close failed: \(error)"
        }
    }

    /// Closes every currently-tracked open gap. A gap whose close fails is
    /// retained (not dropped) so a later retry is still possible, and the
    /// failure is surfaced via `lastError` instead of being silently
    /// swallowed — a write failed here (the `UPDATE`) and it must be
    /// recorded like any other write failure.
    public func closeOpenGaps(at date: Date) {
        var stillOpen: [GapReason: Int64] = [:]
        for (reason, id) in openGapIDsByReason {
            do {
                try store.closeGap(id: id, endedAt: date)
            } catch {
                lastError = "gap close failed: \(error)"
                stillOpen[reason] = id
            }
        }
        openGapIDsByReason = stillOpen
    }

    /// The wall-clock start time of the most recently started event in this
    /// coordinator's store, or nil when there is none. Wraps
    /// `EventStore.latestEventStartedAt()` for callers outside this actor
    /// (`MonitoringSession`, seeding `lastEventAt` at monitoring start) --
    /// `EventStore` itself is not `Sendable` and never leaves this actor.
    public func latestEventStartedAt() -> Date? {
        (try? store.latestEventStartedAt()) ?? nil
    }

    public func status() -> RecordingStatus {
        RecordingStatus(isRecording: recording,
                        currentSegment: segments.currentURL?.lastPathComponent,
                        eventsWritten: eventsWritten,
                        lastError: lastError,
                        freeBytes: storage.freeBytes(),
                        discardedStubCount: segments.discardedStubCount,
                        discardedFrames: segments.discardedFrames,
                        staleOpenGaps: staleOpenGaps,
                        archiveFilesDeleted: archiveFilesDeleted,
                        eventClipsDeleted: eventClipsDeleted,
                        consecutiveWriteFailures: consecutiveWriteFailures)
    }

    /// Applies retention. Failures are recorded in `lastError` rather than
    /// swallowed with `try?`, and what was actually deleted is accumulated
    /// into `archiveFilesDeleted`/`eventClipsDeleted` so a silently-failing
    /// retention loop (disk filling while counts stay flat) is visible
    /// through `status()` instead of assumed to be working.
    public func runRetention(now: Date) {
        let result = storage.applyRetention(now: now)
        archiveFilesDeleted += result.archiveDeleted.count

        do {
            let deletedPaths = try store.deleteEvents(olderThan: result.cutoffForEvents)
            eventClipsDeleted += deletedPaths.count
            for p in deletedPaths {
                do {
                    try FileManager.default.removeItem(atPath: p)
                } catch {
                    lastError = "retention: could not remove orphaned clip \(p): \(error)"
                }
            }
        } catch {
            lastError = "retention: could not delete event rows: \(error)"
        }
    }

    // MARK: Private

    @discardableResult
    private func insertEventRow(event: DetectedEvent, startWallClock: Date, band: FrequencyBand,
                                thresholdDBFS: Double, clipPath: String) -> Bool {
        do {
            _ = try store.insertEvent(startedAt: startWallClock,
                                      durationSec: event.duration,
                                      peakDBFS: event.peakDBFS,
                                      meanDBFS: event.meanDBFS,
                                      band: band,
                                      thresholdDBFS: thresholdDBFS,
                                      deviceUID: deviceUID,
                                      clipPath: clipPath)
            eventsWritten += 1
            recordWriteSuccess()
            return true
        } catch {
            recordWriteFailure(error, at: startWallClock)
            return false
        }
    }

    /// Records a write failure without throwing: distinguishes `.diskFull`
    /// from the generic `.writeFailure` so the evidence trail names the real
    /// cause, per `RecordingError.diskFull`. Also increments
    /// `consecutiveWriteFailures`, the monotonic health signal `status()`
    /// exposes independent of the clobberable `lastError` string.
    private func recordWriteFailure(_ error: Error, at date: Date) {
        lastError = "\(error)"
        consecutiveWriteFailures += 1
        if let recordingError = error as? RecordingError, case .diskFull = recordingError {
            openGap(reason: .diskFull, at: date)
        } else {
            openGap(reason: .writeFailure, at: date)
        }
    }

    /// Resets the consecutive-write-failure streak. Called after any write
    /// (archive append or event-row insert) that actually succeeds.
    private func recordWriteSuccess() {
        consecutiveWriteFailures = 0
    }

    /// Checks `storage.isBelowFloor()` and, if still breached after
    /// retention, stops recording — the application must not pretend to
    /// keep recording onto a full disk (see `StorageManager`'s documented
    /// caller contract). Reclaiming space via retention is the preferred
    /// outcome and must not itself stop recording; only a floor still
    /// breached after retention does. The `.diskFull` gap is opened before
    /// `stop()` so it is captured by `stop()`'s own close-open-gaps step,
    /// honestly recording the interval from the floor breach to the moment
    /// recording actually stopped.
    ///
    /// This used to run inline from `appendArchive`, keyed on frames of
    /// archive audio actually written. With the continuous archive now
    /// flag-disabled by default (`MonitoringSession.isContinuousArchiveEnabled`),
    /// `appendArchive` may never be called at all in a given session, and the
    /// floor would then never be enforced for its entire lifetime — silently
    /// dropping the one guarantee `StorageManager` depends on its caller for.
    /// So this is now `public` and driven externally: `MonitoringSession`'s
    /// 1 Hz recording-status poll calls it directly and unconditionally,
    /// independent of whether the archive is running, which is what keeps
    /// enforcement working with the archive on OR off.
    public func enforceStorageFloor(at date: Date) {
        guard recording else { return }
        guard storage.isBelowFloor() else { return }

        runRetention(now: date)
        guard storage.isBelowFloor() else { return }

        lastError = "disk space below retention floor even after retention; stopping recording"
        openGap(reason: .diskFull, at: date)
        stop()
    }

    /// Opens and immediately closes a gap for an interval whose bounds are
    /// already known (e.g. a skipped event clip). Deliberately bypasses
    /// `openGapIDsByReason`/`closeOpenGaps` so it cannot be conflated with, or
    /// accidentally close, a genuinely still-open gap such as a lost device.
    private func logCompletedInterval(reason: GapReason, start: Date, end: Date) {
        do {
            let id = try store.openGap(startedAt: start, reason: reason)
            try store.closeGap(id: id, endedAt: end)
        } catch {
            lastError = "gap log failed: \(error)"
        }
    }

    private func noteDiscardedStubsIfChanged() {
        let count = segments.discardedStubCount
        guard count != lastReportedDiscardedStubCount else { return }
        lastReportedDiscardedStubCount = count
        lastError = "\(count) archive segment(s) discarded as too short to finalize " +
            "(\(segments.discardedFrames) frames lost)"
    }
}
