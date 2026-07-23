import Testing
import Foundation
import AVFoundation
@testable import BandwatchCore

private func tempPaths() -> RecordingPaths {
    RecordingPaths(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("bwcoord-\(UUID().uuidString)"))
}

private func block(_ n: Int, _ v: Float = 0.1) -> [Float] { [Float](repeating: v, count: n) }

@Test func testStartsNotRecording() async throws {
    let c = try RecordingCoordinator(paths: tempPaths(), sampleRate: 44100)
    let s = await c.status()
    #expect(s.isRecording == false)
    #expect(s.eventsWritten == 0)
    await c.stop()
}

// Scaled up from the brief's original (sampleRate 100, 10 blocks of 100 =
// 1000 frames total): SegmentWriter now discards any segment below
// `minimumReadableFrames` (4608) as an unreadable stub on close (see
// SegmentWriterTests.testStubSegmentBelowMinimumReadableFramesIsDeletedOnClose),
// so 1000 frames would be silently deleted by stop() and `files.count == 1`
// could never hold. 10 blocks of 500 (5000 frames total) clears the
// threshold while segmentDuration (100s => 10,000 frames/segment at this
// sample rate) still guarantees no rollover, preserving the test's original
// intent: one segment, closed and readable after stop().
@Test func testArchiveSegmentIsWrittenAndReadableAfterStop() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 100,
                                     segmentDuration: 100)  // large, no rollover
    await c.start(deviceUID: "DEV")
    for _ in 0..<10 { await c.appendArchive(block(500), wallClock: Date()) }
    await c.stop()

    let files = try FileManager.default.subpathsOfDirectory(atPath: p.archiveDirectory.path)
        .filter { $0.hasSuffix(".flac") }
    #expect(files.count == 1)
    let url = p.archiveDirectory.appendingPathComponent(files[0])
    let f = try AVAudioFile(forReading: url)   // readable because stop() closed it
    #expect(f.length == 5000)
}

@Test func testEventClipIsWrittenAndLogged() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "DEV-9")
    let ev = DetectedEvent(startTime: 10, duration: 3.0, peakDBFS: -12, meanDBFS: -20)
    await c.writeEventClip(samples: block(44100 * 3), event: ev,
                           eventStartWallClock: Date(), clipStartWallClock: Date(), band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let rows = try s.allEvents()
    #expect(rows.count == 1)
    #expect(rows[0].deviceUID == "DEV-9")
    #expect(abs(rows[0].peakDBFS - (-12)) < 0.001)
    #expect(FileManager.default.fileExists(atPath: rows[0].clipPath))
    s.close()
}

@Test func testEventClipAudioIsReadable() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let ev = DetectedEvent(startTime: 0, duration: 1.0, peakDBFS: -6, meanDBFS: -12)
    await c.writeEventClip(samples: block(44100, 0.5), event: ev,
                           eventStartWallClock: Date(), clipStartWallClock: Date(), band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let path = try s.allEvents()[0].clipPath
    s.close()
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    #expect(f.length == 44100)
}

@Test func testGapIsOpenedAndClosed() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let t = Date()
    await c.openGap(reason: .captureStalled, at: t)
    await c.closeOpenGaps(at: t.addingTimeInterval(5))
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps()
    #expect(gaps.contains { $0.reason == .captureStalled && $0.endedAt != nil })
    s.close()
}

@Test func testStopRecordsAShutdownGapBoundary() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    await c.openGap(reason: .noSignal, at: Date())
    await c.stop()   // must close any gap left open

    let s = try EventStore(url: p.databaseURL)
    #expect(try s.openGaps().isEmpty)
    s.close()
}

@Test func testStatusReportsSegmentAndCount() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 100, segmentDuration: 100)
    await c.start(deviceUID: "D")
    await c.appendArchive(block(100), wallClock: Date())
    var s = await c.status()
    #expect(s.isRecording)
    #expect(s.currentSegment != nil)

    let ev = DetectedEvent(startTime: 0, duration: 1, peakDBFS: -5, meanDBFS: -10)
    await c.writeEventClip(samples: block(100), event: ev, eventStartWallClock: Date(), clipStartWallClock: Date(),
                           band: .bassSubwoofer, thresholdDBFS: -40)
    s = await c.status()
    #expect(s.eventsWritten == 1)
    await c.stop()
}

@Test func testAppendBeforeStartIsIgnored() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 100, segmentDuration: 100)
    await c.appendArchive(block(100), wallClock: Date())   // not started
    let s = await c.status()
    #expect(s.isRecording == false)
    #expect(s.currentSegment == nil)
    await c.stop()
}

// MARK: - Constraints beyond the brief

// A clip shorter than SegmentWriter.minimumReadableFrames must not be
// written to disk (it would never open), but the detection is still real
// evidence, so the event row is still logged, and clipPath points to a
// location where no file exists.
@Test func testShortEventClipIsNotWrittenButIsLogged() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let ev = DetectedEvent(startTime: 0, duration: 0.05, peakDBFS: -3, meanDBFS: -9)
    let shortSamples = block(SegmentWriter.minimumReadableFrames - 1)
    await c.writeEventClip(samples: shortSamples, event: ev, eventStartWallClock: Date(), clipStartWallClock: Date(),
                           band: .bassSubwoofer, thresholdDBFS: -40)
    let status = await c.status()
    await c.stop()

    #expect(status.eventsWritten == 1)
    #expect(status.lastError != nil)

    let s = try EventStore(url: p.databaseURL)
    let rows = try s.allEvents()
    #expect(rows.count == 1)
    #expect(!FileManager.default.fileExists(atPath: rows[0].clipPath))
    s.close()
}

// The skipped clip's interval is logged as a gap with real start/end
// timestamps derived from the event itself, since (unlike discarded archive
// stubs) those bounds are known exactly here.
@Test func testShortEventClipLogsAWriteFailureGap() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let ev = DetectedEvent(startTime: 0, duration: 0.05, peakDBFS: -3, meanDBFS: -9)
    let shortSamples = block(SegmentWriter.minimumReadableFrames - 1)
    await c.writeEventClip(samples: shortSamples, event: ev, eventStartWallClock: Date(), clipStartWallClock: Date(),
                           band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps()
    #expect(gaps.contains { $0.reason == .writeFailure && $0.endedAt != nil })
    s.close()
}

// A clip at or above the minimum is written normally, unaffected by the
// short-clip guard.
@Test func testEventClipAtMinimumReadableFramesIsWritten() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let ev = DetectedEvent(startTime: 0, duration: 0.1, peakDBFS: -3, meanDBFS: -9)
    await c.writeEventClip(samples: block(SegmentWriter.minimumReadableFrames), event: ev,
                           eventStartWallClock: Date(), clipStartWallClock: Date(), band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let rows = try s.allEvents()
    #expect(rows.count == 1)
    #expect(FileManager.default.fileExists(atPath: rows[0].clipPath))
    s.close()
}

// C1: a Stop -> Start cycle must not silently kill all future DB logging.
// stop() must close the session (segment + gaps) but leave the store open;
// only shutdown()/deinit closes it for good.
@Test func testStopThenStartPreservesEventLogging() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)

    await c.start(deviceUID: "D")
    let ev1 = DetectedEvent(startTime: 0, duration: 1.0, peakDBFS: -6, meanDBFS: -12)
    await c.writeEventClip(samples: block(44100, 0.5), event: ev1,
                           eventStartWallClock: Date(), clipStartWallClock: Date(), band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    await c.start(deviceUID: "D")
    let ev2 = DetectedEvent(startTime: 0, duration: 1.0, peakDBFS: -6, meanDBFS: -12)
    await c.writeEventClip(samples: block(44100, 0.5), event: ev2,
                           eventStartWallClock: Date(), clipStartWallClock: Date(), band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()
    await c.shutdown()

    let s = try EventStore(url: p.databaseURL)
    let rows = try s.allEvents()
    #expect(rows.count == 2)
    s.close()
}

@Test func testStopCalledTwiceIsSafe() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    await c.stop()
    await c.stop()
    let s = await c.status()
    #expect(s.isRecording == false)
    await c.shutdown()
}

@Test func testStopWithoutStartIsSafe() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.stop()
    let s = await c.status()
    #expect(s.isRecording == false)
    await c.shutdown()
}

// C2: a persistent failure must not insert unbounded gap rows. At most one
// open gap per reason is tracked; repeated opens for the same reason are a
// no-op against the existing open row.
@Test func testRepeatedOpenGapForSameReasonDedupesToOneRow() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let t = Date()
    for _ in 0..<100 {
        await c.openGap(reason: .writeFailure, at: t)
    }
    await c.closeOpenGaps(at: t.addingTimeInterval(5))
    await c.stop()
    await c.shutdown()

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps().filter { $0.reason == .writeFailure }
    #expect(gaps.count == 1)
    s.close()
}

// I4: recovering from one condition must not falsely close a DIFFERENT
// still-open gap. `.writeFailure` opens on any failed append (which happen
// ~21.5/sec in real use), so co-occurrence with e.g. `.noSignal` is
// unremarkable, not exotic -- closing it just because .noSignal recovered
// would record a false `ended_at` in the table whose purpose is proving
// coverage.
@Test func testCloseGapClosesOnlyThatReasonsGap() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let t = Date()
    await c.openGap(reason: .noSignal, at: t)
    await c.openGap(reason: .writeFailure, at: t)

    await c.closeGap(reason: .noSignal, at: t.addingTimeInterval(5))

    // Read while both the coordinator's write handle and this reader are
    // open (WAL mode permits concurrent readers) -- reading AFTER stop()
    // would be pointless here, since stop() itself closes every open gap.
    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps()
    #expect(gaps.contains { $0.reason == .noSignal && $0.endedAt != nil })
    #expect(gaps.contains { $0.reason == .writeFailure && $0.endedAt == nil })
    s.close()

    await c.stop()
    await c.shutdown()
}

// I6: force a genuine I/O failure deterministically by putting a regular
// file where archiveDirectory (a directory) must go, so FLACWriter's
// createDirectory fails for real. The headline guarantee: a failed write
// does not throw, and does record a gap.
@Test func testGenuineWriteFailureDoesNotThrowAndRecordsGapAndFailureCount() async throws {
    let p = tempPaths()
    try FileManager.default.createDirectory(at: p.root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: p.archiveDirectory.path, contents: Data())

    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    await c.appendArchive(block(1000), wallClock: Date())   // must not throw

    let s1 = await c.status()
    #expect(s1.consecutiveWriteFailures > 0)

    await c.stop()
    await c.shutdown()

    let store = try EventStore(url: p.databaseURL)
    let gaps = try store.allGaps()
    #expect(!gaps.isEmpty)
    store.close()
}

// C1: the DB row's started_at must record when the NOISE began (event
// start), not when the CLIP's audio begins (clip start, i.e. event start
// minus pre-roll). MonitoringSession computes both and must pass them
// through distinctly rather than collapsing them into one wall-clock value.
@Test func testEventClipRowRecordsEventStartNotClipStart() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    let ev = DetectedEvent(startTime: 0, duration: 1.0, peakDBFS: -6, meanDBFS: -12)
    let eventStart = Date(timeIntervalSince1970: 1_700_000_000)
    let preRoll: TimeInterval = 10
    let clipStart = eventStart.addingTimeInterval(-preRoll)
    await c.writeEventClip(samples: block(44100, 0.5), event: ev,
                           eventStartWallClock: eventStart, clipStartWallClock: clipStart,
                           band: .bassSubwoofer, thresholdDBFS: -40)
    await c.stop()

    let s = try EventStore(url: p.databaseURL)
    let rows = try s.allEvents()
    #expect(rows.count == 1)
    // The row must carry the event's own start, not the clip's start.
    #expect(abs(rows[0].startedAt.timeIntervalSince(eventStart)) < 1.0)
    // The two are exactly preRoll apart -- collapsing them back to one value
    // would silently reintroduce the falsified timestamp.
    #expect(abs(rows[0].startedAt.timeIntervalSince(clipStart) - preRoll) < 1.0)
    s.close()
}

// I3: a dropped archive window (the bounded delivery stream's buffer was
// full, upstream of this actor) must open a gap recording the discontinuity,
// not just increment a counter nothing reads.
@Test func testDroppedArchiveWindowOpensAGap() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    await c.noteArchiveWindowDropped(at: Date())
    await c.stop()
    await c.shutdown()

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps()
    #expect(gaps.contains { $0.reason == .archiveWindowDropped })
    s.close()
}

// A sustained disk stall drops many windows in a row -- these must dedupe
// to the single already-open row, exactly like every other repeated-reason
// gap open, not grow the table once per dropped window.
@Test func testRepeatedDroppedArchiveWindowsDedupeToOneGapRow() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "D")
    for _ in 0..<50 {
        await c.noteArchiveWindowDropped(at: Date())
    }
    await c.stop()
    await c.shutdown()

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps().filter { $0.reason == .archiveWindowDropped }
    #expect(gaps.count == 1)
    s.close()
}

// C2 defense-in-depth: writeEventClip's "not recording" branch is reachable
// even after MonitoringSession's stop()/shutdown() fix if some OTHER Task
// raced this actor's own `stop()` in between assembling a clip and this
// call landing. The interval is fully known here (unlike the archive-stub
// case), so it must be logged as a real gap, not just a lastError string.
@Test func testEventClipWrittenWhileNotRecordingLogsAWriteFailureGap() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    // Deliberately no start() -- exercises the "not recording" guard.
    let ev = DetectedEvent(startTime: 0, duration: 2.0, peakDBFS: -6, meanDBFS: -12)
    let eventStart = Date(timeIntervalSince1970: 1_700_000_000)
    await c.writeEventClip(samples: block(44100), event: ev,
                           eventStartWallClock: eventStart, clipStartWallClock: eventStart,
                           band: .bassSubwoofer, thresholdDBFS: -40)
    let status = await c.status()
    await c.shutdown()

    #expect(status.lastError != nil)

    let s = try EventStore(url: p.databaseURL)
    let gaps = try s.allGaps()
    #expect(gaps.contains {
        $0.reason == .writeFailure && $0.endedAt != nil
            && abs($0.startedAt.timeIntervalSince(eventStart)) < 1.0
    })
    s.close()
}

// CLIPS ONLY: disk-floor enforcement used to live inline inside
// appendArchive, keyed on frames of archive audio actually written. With the
// continuous archive now flag-disabled by default, appendArchive may never
// be called at all in a session -- if the floor check still lived there, it
// would never run either, silently dropping the guarantee StorageManager's
// caller contract depends on. `enforceStorageFloor` is now public and
// externally driven (MonitoringSession's 1 Hz status poll calls it
// unconditionally), so this test proves the floor is still enforced even
// when `appendArchive` is NEVER called during the whole test -- exactly the
// archive-disabled scenario.
@Test func testEnforceStorageFloorStopsRecordingWithoutAnyArchiveAppend() async throws {
    let p = tempPaths()
    // An unreachable floor forces isBelowFloor() true regardless of real
    // free space on the machine running this test.
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100,
                                     policy: RetentionPolicy(diskFloorBytes: Int64.max))
    await c.start(deviceUID: "D")
    let s0 = await c.status()
    #expect(s0.isRecording == true)

    // Deliberately no appendArchive call anywhere in this test.
    await c.enforceStorageFloor(at: Date())

    let s1 = await c.status()
    #expect(s1.isRecording == false)
    #expect(s1.lastError != nil)
    await c.shutdown()

    let store = try EventStore(url: p.databaseURL)
    let gaps = try store.allGaps()
    #expect(gaps.contains { $0.reason == .diskFull })
    store.close()
}

// A healthy disk must not be affected: enforceStorageFloor is a no-op below
// the real floor, and repeated calls (mirroring the 1 Hz poll) must not stop
// a session that never breaches it.
@Test func testEnforceStorageFloorIsANoOpWhenAboveFloor() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100,
                                     policy: RetentionPolicy(diskFloorBytes: 0))
    await c.start(deviceUID: "D")
    for _ in 0..<5 { await c.enforceStorageFloor(at: Date()) }
    let s = await c.status()
    #expect(s.isRecording == true)
    await c.stop()
    await c.shutdown()
}

// Archive segments discarded as sub-minimum stubs are surfaced through
// status() rather than vanishing silently.
@Test func testDiscardedArchiveStubsAreSurfacedInStatus() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100, segmentDuration: 3600)
    await c.start(deviceUID: "D")
    await c.appendArchive(block(SegmentWriter.minimumReadableFrames - 1), wallClock: Date())
    await c.stop()   // closes the current (sub-minimum) segment, discarding it

    let s = await c.status()
    #expect(s.discardedStubCount == 1)
    #expect(s.discardedFrames == SegmentWriter.minimumReadableFrames - 1)
}

// MARK: - Monitoring span lifecycle (Task 3)

@Test func testStartOpensASpanEndedAtStop() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.start(deviceUID: "dev")
    await c.heartbeatSpan(at: Date())
    await c.stop()
    let s = try EventStore(url: p.databaseURL)
    let spans = try s.spans(from: Date(timeIntervalSince1970: 0),
                            to: Date(timeIntervalSince1970: 4_000_000_000))
    #expect(spans.count == 1)
    #expect(spans[0].endedAt >= spans[0].startedAt)
}

@Test func testHeartbeatRollsEndedAtForward() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    let t0 = Date(timeIntervalSince1970: 1_784_000_000)
    await c.startForTesting(deviceUID: "dev", at: t0)   // see note below
    await c.heartbeatSpan(at: t0.addingTimeInterval(90))
    // Read WITHOUT stopping — simulates reading mid-session (WAL concurrent read).
    let ro = try EventStore(readOnlyURL: p.databaseURL)
    let spans = try ro.spans(from: t0.addingTimeInterval(-10), to: t0.addingTimeInterval(1000))
    #expect(spans.count == 1)
    #expect(abs(spans[0].endedAt.timeIntervalSince(t0.addingTimeInterval(90))) < 1)
    await c.shutdown()
}

@Test func testCrashLeavesSpanFinalizedAtLastHeartbeat() async throws {
    // Open a span, heartbeat to T, then DROP the coordinator without stop()/shutdown()
    // — a crash. The row must read as ended at T (never NULL, never extended to now).
    let p = tempPaths()
    let t0 = Date(timeIntervalSince1970: 1_784_000_000)
    do {
        let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
        await c.startForTesting(deviceUID: "dev", at: t0)
        await c.heartbeatSpan(at: t0.addingTimeInterval(90))
        // no stop()/shutdown(): the coordinator (and its open WAL handle) is dropped here
    }
    let s = try EventStore(url: p.databaseURL)           // fresh reopen = "next launch"
    let spans = try s.spans(from: t0.addingTimeInterval(-10), to: t0.addingTimeInterval(1000))
    #expect(spans.count == 1)
    #expect(abs(spans[0].endedAt.timeIntervalSince(t0.addingTimeInterval(90))) < 1)
}

@Test func testHeartbeatWithNoOpenSpanIsNoOp() async throws {
    let p = tempPaths()
    let c = try RecordingCoordinator(paths: p, sampleRate: 44100)
    await c.heartbeatSpan(at: Date())                    // never started
    let s = try EventStore(url: p.databaseURL)
    #expect(try s.spans(from: Date(timeIntervalSince1970: 0),
                        to: Date(timeIntervalSince1970: 4_000_000_000)).isEmpty)
}
