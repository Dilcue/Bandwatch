import Testing
import Foundation
import AVFoundation
@testable import BandwatchCore

private func sine(freq: Double, amplitude: Float, count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
}

// MARK: - Polling helpers for fire-and-forget-Task assertions
//
// C1/C2/I3's fixes reach the database (or a published status) via Tasks
// that are deliberately fire-and-forget from the caller's perspective
// (`stop()`) or on their own async schedule (the status-polling task). A
// single fixed sleep before asserting is flaky under a heavily parallel
// `swift test` run -- there is no guarantee a short sleep gives a
// backgrounded Task any scheduling opportunity at all when dozens of other
// tests are contending for the same cooperative thread pool. These poll
// instead, so the common case resolves in milliseconds while a genuinely
// slow CI run still passes rather than flaking.

@MainActor
private func waitUntilTrue(timeout: TimeInterval = 5.0, _ probe: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !probe() {
        if Date() >= deadline { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private func eventCount(atRoot root: URL) -> Int {
    guard let store = try? EventStore(url: RecordingPaths(root: root).databaseURL) else { return 0 }
    defer { store.close() }
    return (try? store.allEvents().count) ?? 0
}

private func hasGap(reason: GapReason, atRoot root: URL) -> Bool {
    guard let store = try? EventStore(url: RecordingPaths(root: root).databaseURL) else { return false }
    defer { store.close() }
    return ((try? store.allGaps()) ?? []).contains { $0.reason == reason }
}

@MainActor
@Test func testSessionStartsIdle() {
    let s = MonitoringSession()
    #expect(s.isRunning == false)
    #expect(s.latestFrame == nil)
    #expect(s.recentEvents.isEmpty)
    #expect(s.detectorState == .idle)
}

@MainActor
@Test func testDefaultBandIsBassPreset() {
    let s = MonitoringSession()
    #expect(s.band == .bassSubwoofer)
}

@MainActor
@Test func testIngestProducesAnalysisFrame() {
    let s = MonitoringSession()
    s.ingestForTesting(samples: sine(freq: 50, amplitude: 0.5, count: 8192, sampleRate: 44100), at: 0)
    let frame = s.latestFrame
    #expect(frame != nil)
    #expect(frame!.magnitudes.count == 4096)
    #expect(frame!.bandLevelDBFS > -60)
}

@MainActor
@Test func testQuietAudioProducesLowBandLevel() {
    let s = MonitoringSession()
    s.ingestForTesting(samples: [Float](repeating: 0, count: 8192), at: 0)
    #expect(s.latestFrame!.bandLevelDBFS == BandLevelMeter.silenceFloorDBFS)
}

@MainActor
@Test func testLevelHistoryAccumulates() {
    let s = MonitoringSession()
    for i in 0..<5 {
        s.ingestForTesting(samples: sine(freq: 50, amplitude: 0.5, count: 8192, sampleRate: 44100),
                           at: Double(i) * 0.05)
    }
    #expect(s.levelHistory.count == 5)
}

@MainActor
@Test func testLevelHistoryIsCapped() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)
    for i in 0..<(MonitoringSession.levelHistoryCapacity + 50) {
        s.ingestForTesting(samples: quiet, at: Double(i) * 0.05)
    }
    #expect(s.levelHistory.count == MonitoringSession.levelHistoryCapacity)
}

@MainActor
@Test func testLoudInBandAudioEventuallyProducesEvent() {
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    let quiet = [Float](repeating: 0, count: 8192)

    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    for _ in 0..<60 { s.ingestForTesting(samples: quiet, at: t); t += 0.05 }

    #expect(s.recentEvents.count >= 1)
}

@MainActor
@Test func testDetectedEventSetsLastEventAtToRecentWallClockTime() {
    let s = MonitoringSession()
    #expect(s.lastEventAt == nil)
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    let quiet = [Float](repeating: 0, count: 8192)

    let before = Date()
    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    for _ in 0..<60 { s.ingestForTesting(samples: quiet, at: t); t += 0.05 }

    #expect(s.recentEvents.count >= 1)
    guard let lastEventAt = s.lastEventAt else {
        Issue.record("expected lastEventAt to be set once an event fired")
        return
    }
    // Set to wall-clock "now" at the moment the event fired -- `event.startTime`
    // itself is monotonic and can't be used for this, so this must be close to
    // real time, not derived from the (arbitrary) `at:` monotonic timestamps
    // fed to `ingestForTesting` above.
    #expect(lastEventAt.timeIntervalSince(before) >= 0)
    #expect(abs(lastEventAt.timeIntervalSinceNow) < 5.0)
}

@MainActor
@Test func testOutOfBandAudioProducesNoEvent() {
    let s = MonitoringSession()
    s.band = .bassSubwoofer
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 1.0)

    // 5 kHz is far outside 20-120 Hz.
    let loud = sine(freq: 5000, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }

    #expect(s.recentEvents.isEmpty)
}

@MainActor
@Test func testChangingBandResetsHistoryAndDetector() {
    let s = MonitoringSession()
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    for i in 0..<5 { s.ingestForTesting(samples: loud, at: Double(i) * 0.05) }
    #expect(!s.levelHistory.isEmpty)

    s.band = .applianceWhine
    #expect(s.levelHistory.isEmpty)
    #expect(s.detectorState == .idle)
    #expect(s.suggestedThresholdDBFS == nil)
}

@MainActor
@Test func testApplySuggestedThresholdDoesNothingWhenUnavailable() {
    let s = MonitoringSession()
    let before = s.detectorConfig.triggerDBFS
    s.applySuggestedThreshold()
    #expect(s.detectorConfig.triggerDBFS == before)
}

@MainActor
@Test func testSuggestedThresholdAppearsAfterEnoughQuietSamples() {
    // Throwaway defaults suite: applySuggestedThreshold persists the value, and
    // this must not write to the shared app prefs domain during tests.
    let s = MonitoringSession(defaults: UserDefaults(suiteName: "bw-test-\(UUID().uuidString)")!)
    let quiet = sine(freq: 50, amplitude: 0.001, count: 8192, sampleRate: 44100)
    for i in 0..<BaselineEstimator.minimumSamples {
        s.ingestForTesting(samples: quiet, at: Double(i) * 0.05)
    }
    #expect(s.suggestedThresholdDBFS != nil)

    s.applySuggestedThreshold()
    #expect(abs(s.detectorConfig.triggerDBFS - s.suggestedThresholdDBFS!) < 0.001)
}

@MainActor
@Test func testDetectorStateStaysInSyncAfterConfigChangeMidEvent() {
    // Finding 1: detectorConfig's didSet resets the real EventDetector to
    // .idle, but MonitoringSession.detectorState (the published property the
    // UI observes) must be refreshed too, or it goes stale until the next
    // processWindow — which may never come if the session is stopped/paused.
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<20 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    #expect(s.detectorState == .recording)

    // Change the config to a genuinely different value mid-event, without
    // ingesting anything further.
    s.detectorConfig = DetectorConfig(triggerDBFS: -35, minimumDuration: 0.5, releaseTime: 1.0)
    #expect(s.detectorState == .idle)
}

@MainActor
@Test func testChangingBandClearsLatestFrame() {
    // Finding 2: band's didSet resets the filter/baseline/history/detector
    // but left latestFrame holding a frame computed under the OLD band. The
    // UI would render that stale spectrum against the new band's shaded
    // region. If the session isn't running, the stale frame persists
    // indefinitely, so it must be cleared here too.
    let s = MonitoringSession()
    s.ingestForTesting(samples: sine(freq: 50, amplitude: 0.5, count: 8192, sampleRate: 44100), at: 0)
    #expect(s.latestFrame != nil)

    s.band = .applianceWhine
    #expect(s.latestFrame == nil)
}

@MainActor
@Test func testStopStartCycleLeavesCoherentState() async {
    // Finding 3: stop() -> start() has a genuine race with the previous
    // loop's cancelled Task.sleep continuation (see the analysisGeneration
    // comment in MonitoringSession). That specific interleaving is timing-
    // dependent and cannot be forced deterministically without depending on
    // task-scheduling order, which would make the test flaky — so it is
    // NOT covered here. What this test pins instead is the simpler,
    // deterministic invariant: after a real stop() -> start() cycle, the
    // session settles into a coherent state (running, with exactly one
    // analysis task alive).
    //
    // This drives the real capture path (AudioCaptureEngine), which
    // requires actual microphone permission to reach the running state at
    // all. In sandboxed/CI environments without a granted permission,
    // start() takes the permissionDenied branch, isRunning never becomes
    // true, and there is nothing left to assert — so the test is a no-op
    // there, mirroring the existing hardware-dependent gap documented in
    // AudioCaptureEngineTests.swift.
    //
    // This guard checks currentPermission() only — never requestPermission()
    // — specifically so this test cannot trigger a real system permission
    // prompt (which would hang or block the headless test process).
    guard AudioCaptureEngine.currentPermission() == .granted else { return }
    // The explicit-device guard added in Task 2 refuses to run start() at all
    // when there is no USABLE selected device — so this test, which drives
    // the real capture path, must explicitly pin one rather than relying on
    // `MonitoringSession()`'s default (production) UserDefaults domain, whose
    // persisted preference is untracked ambient state that may name a device
    // not currently connected on whatever machine runs this. A fresh defaults
    // suite plus the first actually-enumerated real device makes the test
    // deterministic regardless of what's persisted for the real app.
    guard let device = CoreAudioInputDevices().available().first else { return }
    let defaults = UserDefaults(suiteName: "bw-test-\(UUID().uuidString)")!
    defaults.set(device.uid, forKey: MonitoringSession.inputDeviceDefaultsKey)
    let s = MonitoringSession(deviceEnumerator: CoreAudioInputDevices(), defaults: defaults)
    #expect(s.hasUsableSelectedDevice())
    // C2: this test drives the real start(), which — if recording were left
    // enabled — would build a real RecordingCoordinator at
    // RecordingPaths.defaultRoot() (~/Library/Application Support/Bandwatch)
    // and write to the user's real evidence database. Disabling recording
    // AND pointing recordingRoot at a temp directory is belt-and-braces so
    // neither one alone being forgotten (here or in a future edit) can reach
    // the production path.
    s.isRecordingEnabled = false
    s.recordingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")

    await s.start()
    #expect(s.isRunning)
    #expect(s.hasAnalysisTaskForTesting)

    s.stop()
    #expect(!s.isRunning)

    await s.start()
    #expect(s.isRunning)
    #expect(s.hasAnalysisTaskForTesting)

    s.stop()
}

@MainActor
@Test func testRecordingStatusIsPopulatedByPollingAndClearedByStop() async {
    // Recording status only ever exists behind a real RecordingCoordinator,
    // which is only built once `isRunning` becomes true -- which itself
    // requires the real capture path (AudioCaptureEngine) to succeed, which
    // requires actual microphone permission. Same documented gap as
    // `testStopStartCycleLeavesCoherentState` above: a no-op in a
    // sandboxed/CI environment without granted permission, guarded the same
    // way so it can never trigger a real system permission prompt.
    guard AudioCaptureEngine.currentPermission() == .granted else { return }
    // See testStopStartCycleLeavesCoherentState's comment: the explicit-
    // device guard needs a USABLE selected device to let start() reach the
    // real capture path at all, so this pins one deterministically rather
    // than depending on whatever is persisted in the production defaults
    // domain on whatever machine runs this.
    guard let device = CoreAudioInputDevices().available().first else { return }
    let defaults = UserDefaults(suiteName: "bw-test-\(UUID().uuidString)")!
    defaults.set(device.uid, forKey: MonitoringSession.inputDeviceDefaultsKey)
    let s = MonitoringSession(deviceEnumerator: CoreAudioInputDevices(), defaults: defaults)
    // Recording must be enabled to exercise the polling task at all, but
    // must never touch the real evidence database -- point recordingRoot at
    // a fresh temp directory, never the production default.
    s.recordingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")

    #expect(s.recordingStatus == nil)

    await s.start()
    #expect(s.isRunning)

    // The polling task fetches status immediately on start (no leading sleep
    // before its first read -- see MonitoringSession's `recordingStatusTask`).
    // Wait for the condition rather than a fixed interval: under parallel test
    // load the first poll can land later than any single short sleep, which
    // otherwise makes this real-capture test flaky.
    var statusLanded = false
    for _ in 0..<40 {   // up to ~2s
        if s.recordingStatus != nil { statusLanded = true; break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(statusLanded)
    #expect(s.recordingStatus?.isRecording == true)

    s.stop()
    // stop() must clear recordingStatus -- a stopped session must never go
    // on displaying its last-known recording health as if it were current.
    #expect(s.recordingStatus == nil)
}

@MainActor
@Test func testRecentEventsAreCapped() {
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -100, minimumDuration: 0.05,
                                      releaseTime: 0.05, maximumDuration: 0.1)
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<400 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    // Assert the cap is actually reached, not just respected — `<= 100`
    // would pass vacuously if the detector emitted zero events.
    #expect(s.recentEvents.count == 100)
}

// MARK: - Fix 1: staleness/stall guard
//
// The real analysis loop is a private Task, woken by a live Task.sleep timer,
// that only runs once `start()` has a genuinely running AudioCaptureEngine —
// which itself requires granted microphone permission. None of that is
// controllable deterministically from a test (there is no way to force the
// real tap to freeze without mocking AVAudioEngine, which is out of scope
// here), so the loop's Task body itself cannot be exercised end-to-end.
// `processLoopIteration(now:)` is the exact per-tick decision that Task body
// runs after every sleep; it's exposed at internal visibility precisely so
// this decision can be driven directly, without a timer or real capture.

@MainActor
@Test func testProcessLoopIterationSkipsAnalysisWhenRingBufferDoesNotAdvance() {
    let s = MonitoringSession()
    #expect(s.levelHistory.isEmpty)

    // No samples were ever written to the session's ring buffer (this test
    // never calls ingestForTesting, only processLoopIteration directly), so
    // totalWritten stays at 0 across repeated ticks — this simulates a
    // frozen/dead capture. Stay under the 3s stall threshold so we're only
    // proving the "skip analysis" half.
    s.processLoopIteration(now: 0.0)
    s.processLoopIteration(now: 1.0)
    s.processLoopIteration(now: 2.0)

    #expect(s.levelHistory.isEmpty)
    #expect(s.latestFrame == nil)
    #expect(s.lastError == nil)
}

// MARK: - Level smoothing (time weighting)

@MainActor
@Test func testDefaultTimeWeightingIsFast() {
    let s = MonitoringSession()
    #expect(s.timeWeighting == .fast)
}

@MainActor
@Test func testAlternatingLoudQuietProducesLessJitteryLevelHistoryThanRawLevels() {
    // Regression for the observed real-world failure: the raw per-frame band
    // level thrashes 12-15 dB frame to frame, fragmenting one continuous
    // noise into several detector events. This pins that the smoother is
    // actually wired into the session's pipeline: levelHistory (fed by the
    // SAME smoothed value used by the detector) must be far less jittery
    // than the raw per-frame levels would be.
    let s = MonitoringSession()

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)   // raw level well above -20 dBFS
    let quiet = sine(freq: 50, amplitude: 0.02, count: 8192, sampleRate: 44100) // raw level well below -20 dBFS, but not silence-floor-clamped

    var t = 0.0
    for i in 0..<60 {
        s.ingestForTesting(samples: (i % 2 == 0) ? loud : quiet, at: t)
        t += 0.0464 // ~real hop interval (2048/44100)
    }

    let steadyState = s.levelHistory.suffix(40)
    let smoothedSpread = steadyState.max()! - steadyState.min()!

    // Establish the RAW (unsmoothed) spread independently, via a bare
    // BandLevelMeter over the same two signals, to compare against.
    let analyzer = SpectrumAnalyzer(fftSize: 8192, sampleRate: 44100)!
    let meter = BandLevelMeter(analyzer: analyzer)
    let rawLoud = meter.level(magnitudes: analyzer.analyze(loud), band: .bassSubwoofer)
    let rawQuiet = meter.level(magnitudes: analyzer.analyze(quiet), band: .bassSubwoofer)
    let rawSpread = rawLoud - rawQuiet

    #expect(rawSpread > 10.0) // sanity check this scenario actually thrashes like the real bug
    #expect(smoothedSpread < rawSpread * 0.5)
}

@MainActor
@Test func testChangingTimeWeightingDoesNotResetBaselineOrDetector() {
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<20 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    #expect(s.detectorState == .recording)

    s.timeWeighting = .slow

    // Changing the weighting must not have reset the detector's in-progress
    // event state -- it's a response-speed preference, not a re-tune.
    #expect(s.detectorState == .recording)
    #expect(s.timeWeighting == .slow)
}

@MainActor
@Test func testChangingBandResetsSmootherAlongWithBaselineAndDetector() {
    // The smoother's running value is meaningless once the band (and hence
    // the level signal's meaning) changes; ingesting a very different level
    // right after a band change must not be dragged toward the old band's
    // running value.
    let s = MonitoringSession()
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    for i in 0..<10 { s.ingestForTesting(samples: loud, at: Double(i) * 0.05) }
    #expect(s.latestFrame!.bandLevelDBFS > -20)

    s.band = .applianceWhine
    // Silence under the new band should read at (or very near) the silence
    // floor immediately -- not pulled toward the old band's loud running
    // level, which would happen if the smoother weren't reset.
    s.ingestForTesting(samples: [Float](repeating: 0, count: 8192), at: 10.0)
    #expect(s.latestFrame!.bandLevelDBFS == BandLevelMeter.silenceFloorDBFS)
}

// MARK: - Input health (dead signal path detection)

@MainActor
@Test func testSustainedSilenceBeyondDurationSetsNoSignal() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)

    // All-zero input reads at BandLevelMeter.silenceFloorDBFS (-120 dBFS),
    // comfortably below the -90 dBFS noSignalThresholdDBFS.
    var t = 0.0
    while t <= MonitoringSession.noSignalDuration + 1.0 {
        s.ingestForTesting(samples: quiet, at: t)
        t += 1.0
    }

    #expect(s.inputHealth == .noSignal)
}

@MainActor
@Test func testSilenceShorterThanDurationStaysHealthy() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)

    var t = 0.0
    while t < MonitoringSession.noSignalDuration - 1.0 {
        s.ingestForTesting(samples: quiet, at: t)
        t += 1.0
    }

    #expect(s.inputHealth == .healthy)
}

@MainActor
@Test func testNoSignalRecoversAutomaticallyOnLoudAudio() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)

    var t = 0.0
    while t <= MonitoringSession.noSignalDuration + 1.0 {
        s.ingestForTesting(samples: quiet, at: t)
        t += 1.0
    }
    #expect(s.inputHealth == .noSignal)

    // A single loud in-band window, with no restart, must restore health.
    t += 0.05
    s.ingestForTesting(samples: loud, at: t)
    #expect(s.inputHealth == .healthy)
}

@MainActor
@Test func testLevelJustAboveThresholdStaysHealthyIndefinitely() {
    // A quiet but genuinely live room must never be reported as a dead
    // signal path. Use an amplitude empirically confirmed to land modestly
    // above noSignalThresholdDBFS (-90 dBFS).
    let s = MonitoringSession()
    let quietButLive = sine(freq: 50, amplitude: 0.01, count: 8192, sampleRate: 44100)

    var t = 0.0
    while t <= MonitoringSession.noSignalDuration + 5.0 {
        s.ingestForTesting(samples: quietButLive, at: t)
        t += 1.0
    }

    #expect(s.latestFrame!.bandLevelDBFS > MonitoringSession.noSignalThresholdDBFS)
    #expect(s.inputHealth == .healthy)
}

@MainActor
@Test func testNoSignalDoesNotSetLastError() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)

    var t = 0.0
    while t <= MonitoringSession.noSignalDuration + 1.0 {
        s.ingestForTesting(samples: quiet, at: t)
        t += 1.0
    }

    #expect(s.inputHealth == .noSignal)
    #expect(s.lastError == nil)
}

@MainActor
@Test func testChangingBandResetsInputHealthAndTimer() {
    let s = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)

    var t = 0.0
    while t <= MonitoringSession.noSignalDuration + 1.0 {
        s.ingestForTesting(samples: quiet, at: t)
        t += 1.0
    }
    #expect(s.inputHealth == .noSignal)

    s.band = .applianceWhine
    #expect(s.inputHealth == .healthy)

    // The timer must also have been reset, not just the published verdict:
    // a further brief dip under the new band should not immediately re-trip.
    t += 1.0
    s.ingestForTesting(samples: quiet, at: t)
    #expect(s.inputHealth == .healthy)
}

@MainActor
@Test func testProcessLoopIterationFailsSessionAfterStallThreshold() {
    let s = MonitoringSession()

    // Same frozen-buffer scenario, but now hold it stalled for >= 3 seconds
    // (the documented captureStallThreshold) so the session declares capture
    // failed rather than silently continuing to "monitor" nothing.
    s.processLoopIteration(now: 0.0)
    s.processLoopIteration(now: 1.5)
    s.processLoopIteration(now: 3.0)

    #expect(s.lastError == .captureStalled)
    #expect(s.isRunning == false)
    #expect(s.levelHistory.isEmpty)
}

// MARK: - Fix: display publishing throttled to displayInterval, decoupled
// from the ~21.5 Hz analysis rate.
//
// MonitoringSession.displayInterval is 1/12 s (~0.083s), well above the
// ~0.0464s real hop interval (2048/44100). These tests deliberately ingest
// frames spaced well *inside* one displayInterval to prove two things stay
// true under throttling: (1) detection is computed from every single frame,
// never gated on the display cadence, and (2) levelHistory publishing is
// genuinely batched, not simply relabelled per-frame publishing.

@MainActor
@Test func testDetectorSeesEveryFrameRegardlessOfDisplayThrottling() {
    // dt is far smaller than displayInterval (~0.083s), so several ingests
    // land inside a single publish window -- exactly the scenario display
    // throttling must not affect.
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.03, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    let dt = 0.01
    var t = 0.0
    var recordingStartedAtFrame: Int?
    for i in 0..<10 {
        s.ingestForTesting(samples: loud, at: t)
        if recordingStartedAtFrame == nil && s.detectorState == .recording {
            recordingStartedAtFrame = i
        }
        t += dt
    }

    // minimumDuration is 0.03s and dt is 0.01s, so the candidate must qualify
    // once 0.03s of above-threshold signal has elapsed -- at the 4th ingest
    // (index 3, elapsed 3 * 0.01 = 0.03s), the same instant this would happen
    // with no display throttling at all. If display throttling were (wrongly)
    // gating the detector, this would fire later, aligned to a ~0.083s
    // publish boundary instead.
    #expect(recordingStartedAtFrame == 3)
}

@MainActor
@Test func testLevelHistoryDoesNotGrowOnEveryFrameWithinADisplayInterval() {
    let s = MonitoringSession()
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)

    // First ingest always publishes (nothing published yet).
    s.ingestForTesting(samples: loud, at: 0.0)
    #expect(s.levelHistory.count == 1)

    // These three all land within one displayInterval (~0.083s) of the last
    // publish (dt = 0.01s each, total elapsed 0.03s < 0.083s) -- levelHistory
    // must NOT grow on any of them.
    s.ingestForTesting(samples: loud, at: 0.01)
    #expect(s.levelHistory.count == 1)
    s.ingestForTesting(samples: loud, at: 0.02)
    #expect(s.levelHistory.count == 1)
    s.ingestForTesting(samples: loud, at: 0.03)
    #expect(s.levelHistory.count == 1)

    // Once displayInterval has genuinely elapsed since the last publish
    // (0.09s > 0.0833s), the next ingest must publish and catch the working
    // copy up in one batch -- not one at a time.
    s.ingestForTesting(samples: loud, at: 0.09)
    #expect(s.levelHistory.count == 5)
}

@MainActor
@Test func testLevelHistoryContainsEverySampleAcrossSeveralDisplayIntervals() {
    // No samples are lost to throttling: the working copy accumulates every
    // frame, and levelHistory (once caught up) reflects all of them.
    let s = MonitoringSession()
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)

    let dt = 0.01 // well inside one displayInterval (~0.083s)
    let frameCount = 40 // spans several displayInterval boundaries at this dt
    var t = 0.0
    for _ in 0..<frameCount {
        s.ingestForTesting(samples: loud, at: t)
        t += dt
    }
    // Advance well past the last publish so the final batch is flushed.
    s.ingestForTesting(samples: loud, at: t + MonitoringSession.displayInterval)

    #expect(s.levelHistory.count == frameCount + 1)
}

// MARK: - Recording wiring (Task 8)

@MainActor
@Test func testRecordingEnabledByDefaultButRootIsNilUntilConfigured() {
    // Recording is enabled by default (matching real usage), but the
    // destination root is nil until explicitly configured -- start() only
    // then falls back to RecordingPaths.defaultRoot() (see C2). Nothing here
    // defaults a test into safety: any test that calls start() must itself
    // set isRecordingEnabled = false and/or point recordingRoot at a
    // temporary directory, or it risks writing to the user's real evidence
    // database.
    let s = MonitoringSession()
    #expect(s.isRecordingEnabled == true)
    #expect(s.recordingRoot == nil)
}

@MainActor
@Test func testFilteredAudioIsWhatReachesTheRecorder() {
    // The filter must be in the path: a 5 kHz tone in a 20-120 Hz band
    // must be attenuated to near silence before any recording happens.
    let s = MonitoringSession()
    s.band = .bassSubwoofer
    let loud5k = sine(freq: 5000, amplitude: 0.8, count: 8192, sampleRate: 44100)
    s.ingestForTesting(samples: loud5k, at: 0)
    // Band level reflects the FFT, which is unfiltered; the recorded path is
    // filtered. Assert the session exposes a filtered tap for verification.
    let filtered = s.lastFilteredSamplesForTesting
    #expect(filtered != nil)
    let peak = filtered!.map { abs($0) }.max() ?? 0
    #expect(peak < 0.1)   // 5 kHz is far outside 20-120 Hz
}

@MainActor
@Test func testInBandAudioSurvivesTheFilter() {
    let s = MonitoringSession()
    s.band = .bassSubwoofer
    let loud55 = sine(freq: 55, amplitude: 0.8, count: 8192, sampleRate: 44100)
    // Run several windows so the filter settles.
    for i in 0..<8 { s.ingestForTesting(samples: loud55, at: Double(i) * 0.046) }
    let peak = (s.lastFilteredSamplesForTesting ?? []).map { abs($0) }.max() ?? 0
    #expect(peak > 0.3)
}

@MainActor
@Test func testPreRollBufferHoldsPreRollPlusMaxEventPlusRelease() {
    // The clip spans preRoll + event duration + releaseTime. The buffer must
    // cover the worst case or a long event's pre-roll is silently truncated.
    let s = MonitoringSession()
    #expect(MonitoringSession.preRollSeconds == 10)
    let worstCase = MonitoringSession.preRollSeconds
        + s.detectorConfig.maximumDuration
        + s.detectorConfig.releaseTime
    #expect(Double(s.filteredBufferCapacityForTesting) >= 44100 * worstCase)
}

// MARK: - M3.5: recorded audio must match real elapsed time, not up to 4x it
//
// The M3 recording bug, measured on a real 240-second session: the archive
// held 446 seconds of audio (1.86x real time). `processWindow` filtered and
// wrote the FULL fftSize=8192 analysis window on every hop, but consecutive
// windows overlap 75% (hopSize=2048), so the same audio was filtered and
// written up to 4x -- the shortfall from a clean 4x to the measured 1.86x
// was the bounded archive stream then dropping roughly 54% of those
// (duplicated) windows. These tests pin exactly the check that would have
// caught this immediately: recorded sample count against real elapsed time.

@MainActor
@Test func testRecordedSampleCountMatchesArrivedAudioNotUpToFourTimesIt() {
    let sampleRate = 44100.0
    let fftSize = 8192
    let hopSize = 2048
    let s = MonitoringSession(sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)

    // Feed windows at the true hop cadence -- exactly what the live analysis
    // loop does: a fresh fftSize-sample window arrives every hopSize/sampleRate
    // seconds. Content doesn't matter here, only how much of it is consumed
    // for recording.
    let dt = Double(hopSize) / sampleRate
    let windowCount = 50
    let window = [Float](repeating: 0, count: fftSize)
    for i in 0..<windowCount {
        s.ingestForTesting(samples: window, at: Double(i) * dt)
    }

    // Real audio "arrived" at fftSize for the very first window (there is no
    // prior history to dedupe against) and hopSize for every window after --
    // this is the total real-time span actually covered, in samples.
    let expectedArrived = fftSize + (windowCount - 1) * hopSize
    #expect(s.recordedSampleCountForTesting == expectedArrived)

    // Pre-fix, every window recorded the full fftSize regardless of overlap
    // -- windowCount * fftSize, roughly 4x expectedArrived once steady state
    // is reached (fftSize / hopSize == 4).
    let buggyCount = windowCount * fftSize
    #expect(s.recordedSampleCountForTesting != buggyCount)

    let ratio = Double(s.recordedSampleCountForTesting) / Double(expectedArrived)
    #expect(abs(ratio - 1.0) < 0.0001)
}

@MainActor
@Test func testFilteredBufferAccumulatesAtRealTimeRateAcrossPreRollSpan() {
    // With the fix, filteredBuffer receives exactly the new audio each
    // window, so it accumulates at the true real-time rate. Feed enough
    // real-cadence audio to exceed preRoll + maxDuration + releaseTime, then
    // confirm the buffer holds a real, contiguous span of that length --
    // not one stuffed with duplicated audio, which would have satisfied a
    // bare `.count` check even before the fix (since the buggy path also
    // wrote fast enough to fill the buffer, just with 4x-redundant content).
    let sampleRate = 44100.0
    let fftSize = 8192
    let hopSize = 2048
    let s = MonitoringSession(sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.05,
                                       releaseTime: 1.0, maximumDuration: 2.0)
    let worstCase = MonitoringSession.preRollSeconds
        + s.detectorConfig.maximumDuration
        + s.detectorConfig.releaseTime

    let dt = Double(hopSize) / sampleRate
    let windowCount = Int((worstCase / dt).rounded(.up)) + 5
    let quiet = [Float](repeating: 0, count: fftSize)
    for i in 0..<windowCount {
        s.ingestForTesting(samples: quiet, at: Double(i) * dt)
    }

    // Total recorded content must equal the real elapsed span, in seconds --
    // not some multiple of it.
    let expectedArrivedSamples = fftSize + (windowCount - 1) * hopSize
    #expect(s.recordedSampleCountForTesting == expectedArrivedSamples)

    // The buffer must hold a full, contiguous worst-case clip span: this is
    // exactly what an event's pre-roll fetch (`filteredBuffer.latest(...)`)
    // relies on.
    let requestedFrames = Int(sampleRate * worstCase)
    let clip = s.filteredBufferLatestForTesting(requestedFrames)
    #expect(clip.count == requestedFrames)
}

@MainActor
@Test func testDetectorStateTransitionsPublishImmediatelyNotOnDisplayCadence() {
    // State transitions (detectorState, inputHealth, ...) are never gated on
    // displayInterval -- a user must see them the same frame they occur.
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.03, releaseTime: 1.0)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    let dt = 0.01 // well inside one displayInterval
    var t = 0.0
    for _ in 0..<4 {
        s.ingestForTesting(samples: loud, at: t)
        t += dt
    }
    // By t=0.03 (4th ingest, index 3) the candidate has qualified -- and this
    // must already be visible, even though no display publish is due yet at
    // this dt.
    #expect(s.detectorState == .recording)

    // Same expectation for inputHealth reaching .noSignal: it must flip the
    // instant the duration threshold is crossed, not wait for a display
    // publish. Use a fresh session with widely-spaced (real-world) timestamps
    // so this is unambiguous.
    let s2 = MonitoringSession()
    let quiet = [Float](repeating: 0, count: 8192)
    var t2 = 0.0
    while t2 <= MonitoringSession.noSignalDuration {
        s2.ingestForTesting(samples: quiet, at: t2)
        t2 += 1.0
    }
    #expect(s2.inputHealth == .noSignal)
}

// MARK: - C1/C2/I3: final M3 review fixes
//
// `startRecordingForTesting(root:)` brings the session into the same
// "recording" state `start()` reaches once its `AudioCaptureEngine` starts
// successfully, WITHOUT requiring a real microphone or granted TCC
// permission -- unlike `testStopStartCycleLeavesCoherentState` and
// `testRecordingStatusIsPopulatedByPollingAndClearedByStop` above, which
// both no-op without granted mic permission, these tests run unconditionally
// in any environment.

@MainActor
@Test func testEventInProgressAtStopIsWrittenToStore() async throws {
    // C2: an event still in progress at Stop was shown in recentEvents (the
    // UI) but NEVER reached the database -- stop()'s
    // `detector.finish()`/`appendEvent()` only ever pushed to the in-memory
    // list. Before the fix, this test's final assertion failed with
    // `rows.count == 0`: the UI claimed an event the database never
    // received, silently, with no gap explaining the absence either.
    let s = MonitoringSession()
    // A long release time keeps the detector in `.recording` for the whole
    // ingest loop below -- the event must still be genuinely in progress
    // (not yet emitted through the normal processWindow path) when stop()
    // is called.
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 5.0)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    #expect(s.detectorState == .recording)
    #expect(s.recentEvents.isEmpty)   // not yet emitted -- still in progress

    s.stop()
    // The UI sees it immediately (pre-existing, unaffected by this fix).
    #expect(s.recentEvents.count == 1)

    // Give stop()'s fire-and-forget Task (write the clip, THEN c.stop() --
    // see its doc comment for why that ordering is guaranteed) a chance to
    // actually reach the coordinator actor and finish the disk I/O.
    await waitUntilTrue { eventCount(atRoot: root) == 1 }

    let store = try EventStore(url: RecordingPaths(root: root).databaseURL)
    let rows = try store.allEvents()
    store.close()
    #expect(rows.count == 1)
    #expect(FileManager.default.fileExists(atPath: rows.first?.clipPath ?? ""))
}

@MainActor
@Test func testEventInProgressAtCaptureStallIsWrittenToStore() async throws {
    // C2 also names failCaptureStalled explicitly -- same bug, same fix,
    // same shape of test.
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.1, releaseTime: 5.0)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<10 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    #expect(s.detectorState == .recording)

    // ingestForTesting now writes through the ring buffer (the M3.6 splice
    // fix -- see its doc comment), so totalWritten has genuinely advanced by
    // the time the ingest loop above finishes. The first processLoopIteration
    // call after it observes that advance and runs one more (harmless)
    // analysis pass rather than registering a stall -- exactly what the real
    // loop's very next tick would do. Only the calls AFTER that priming call,
    // with no further ring-buffer advance, are genuinely frozen and count
    // toward the 3s stall threshold -- so an extra priming call, and the
    // subsequent timestamps shifted out to compensate, are needed to still
    // reach the threshold below (compare with
    // testProcessLoopIterationFailsSessionAfterStallThreshold, which never
    // calls ingestForTesting and so needs no priming call).
    s.processLoopIteration(now: t)
    s.processLoopIteration(now: t + 1.5)
    s.processLoopIteration(now: t + 3.0)
    s.processLoopIteration(now: t + 4.5)

    #expect(s.lastError == .captureStalled)
    #expect(s.isRunning == false)
    #expect(s.recentEvents.count == 1)

    await waitUntilTrue { eventCount(atRoot: root) == 1 }

    let store = try EventStore(url: RecordingPaths(root: root).databaseURL)
    let rows = try store.allEvents()
    store.close()
    #expect(rows.count == 1)
}

@MainActor
@Test func testStartSeedsLastEventAtFromExistingStoreHistory() async throws {
    // `recentEvents` is in-memory only and resets on restart, so `lastEventAt`
    // must be seeded from the database at monitoring start -- otherwise the
    // readout would wrongly show "none" right after a restart even though the
    // store has real history.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    let seededDate = Date(timeIntervalSince1970: 1_784_000_000)
    // Insert an event into the store BEFORE the session ever starts, exactly
    // as a real prior run would have left behind.
    let store = try EventStore(url: RecordingPaths(root: root).databaseURL)
    _ = try store.insertEvent(startedAt: seededDate, durationSec: 1, peakDBFS: -10,
                              meanDBFS: -20, band: .bassSubwoofer, thresholdDBFS: -40,
                              deviceUID: "DEV-1", clipPath: "/tmp/seed.flac")
    store.close()

    let s = MonitoringSession()
    #expect(s.lastEventAt == nil)
    await s.startRecordingForTesting(root: root)

    guard let lastEventAt = s.lastEventAt else {
        Issue.record("expected lastEventAt to be seeded from existing store history")
        return
    }
    #expect(abs(lastEventAt.timeIntervalSince(seededDate)) < 1.0)
    s.stop()
}

@MainActor
@Test func testShutdownAwaitsWriteAndRecordsShutdownGapBoundary() async throws {
    // C1: the crux of the fix. shutdown() must not return until the
    // coordinator has actually finished writing any in-progress event's
    // clip -- a FLAC file is unreadable until its writer is released
    // (verified empirically). This is checked with NO extra sleep/retry
    // after `await s.shutdown()`: if shutdown() only fired a detached Task
    // (the bug being fixed), reading the file back immediately would be a
    // race that fails at least some of the time depending on scheduling;
    // because shutdown() genuinely awaits the coordinator all the way
    // through, this is deterministic.
    let s = MonitoringSession()
    // A long release time keeps the detector in `.recording` for the whole
    // ingest loop below -- the event must still be genuinely in progress
    // (not yet emitted through the normal processWindow path) when
    // shutdown() is called.
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.5, releaseTime: 5.0)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    #expect(s.detectorState == .recording)

    await s.shutdown()

    #expect(s.isRunning == false)

    let paths = RecordingPaths(root: root)
    let store = try EventStore(url: paths.databaseURL)
    let rows = try store.allEvents()
    let gaps = try store.allGaps()
    store.close()

    #expect(rows.count == 1)
    // Throws if the file is not a valid, finalized FLAC stream -- i.e. if
    // its writer had not actually been released yet.
    _ = try AVAudioFile(forReading: URL(fileURLWithPath: rows[0].clipPath))

    // A deliberate, benign boundary marker distinguishing "the app was
    // quit here" from every other (failure) gap reason -- and, per
    // `GapReason.shutdown`'s doc comment, previously had ZERO producers
    // anywhere in the codebase despite being defined.
    #expect(gaps.contains { $0.reason == .shutdown && $0.endedAt != nil })
}

@MainActor
@Test func testShutdownIsNoOpWhenSessionIsNotRunning() async {
    let s = MonitoringSession()
    await s.shutdown()   // must not crash/hang when there is nothing to shut down
    #expect(s.isRunning == false)
}

// A normal, detector-emitted event (via the live processWindow path, not a
// forced stop()) still reaches the event store and its clip lands on disk.
@MainActor
@Test func testDetectedEventWritesEventClipToStore() async throws {
    let s = MonitoringSession()
    s.detectorConfig = DetectorConfig(triggerDBFS: -40, minimumDuration: 0.05, releaseTime: 0.2)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    // Feed a loud in-band tone, then a quiet tail past releaseTime -- the
    // detector only emits an event (via the normal processWindow path, not a
    // forced stop()) once the release window elapses after the loud period
    // ends, mirroring testLoudInBandAudioEventuallyProducesEvent.
    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    let quiet = [Float](repeating: 0, count: 8192)
    var t = 0.0
    for _ in 0..<40 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }
    for _ in 0..<60 { s.ingestForTesting(samples: quiet, at: t); t += 0.05 }

    await waitUntilTrue { eventCount(atRoot: root) == 1 }

    let paths = RecordingPaths(root: root)
    let store = try EventStore(url: paths.databaseURL)
    let rows = try store.allEvents()
    store.close()
    #expect(rows.count == 1)
    #expect(FileManager.default.fileExists(atPath: rows.first?.clipPath ?? ""))

    s.stop()
}

// `recordingStatus` becomes populated via the 1 Hz status-poll task under
// the no-mic `startRecordingForTesting` seam -- unlike
// `testRecordingStatusIsPopulatedByPollingAndClearedByStop` above, which
// requires real microphone permission and no-ops in CI, this runs
// unconditionally. De-flaked with `waitUntilTrue`: under full-suite CPU
// load the poll can take longer than any hard-coded delay.
@MainActor
@Test func testRecordingStatusIsPopulatedUnderTheNoMicTestSeam() async throws {
    let s = MonitoringSession()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    let loud = sine(freq: 50, amplitude: 0.8, count: 8192, sampleRate: 44100)
    var t = 0.0
    for _ in 0..<20 { s.ingestForTesting(samples: loud, at: t); t += 0.05 }

    await waitUntilTrue { s.recordingStatus != nil }
    #expect(s.recordingStatus?.isRecording == true)

    s.stop()
}

// MARK: - Click-fix regression: recording must not splice at window
// boundaries when the analysis loop's timing jitters.
//
// The M3 splice bug: `processWindow` used to derive how many samples were
// "new" from ELAPSED TIME (`(time - lastRecordedAnalysisTime) * sampleRate`),
// not from how much audio the capture thread had actually written to the
// ring buffer. The real analysis loop wakes via `Task.sleep`, which jitters
// by a millisecond or two per tick -- enough that consecutive elapsed-time
// deltas do not land on exactly `hopSize` samples, so each window boundary
// either re-records a few already-recorded samples (a duplicate splice) or
// skips a few that never get recorded (a dropped splice). Both click.
//
// This test drives `ingestForTesting` with a single continuous sine sliced
// into true fftSize-sized, hopSize-overlapping windows -- exactly what the
// live loop's `ringBuffer.latest(fftSize)` would return each tick -- at
// JITTERED timestamps, mirroring real Task.sleep drift. It must fail before
// the fix (elapsed-time-derived count, sensitive to the jitter) and pass
// after it (ring-buffer-`totalWritten`-derived count, which does not depend
// on `time` at all).
@MainActor
@Test func testContinuousSineRecordsWithoutSpliceUnderJitteredAnalysisTiming() {
    let sampleRate = 44100.0
    let fftSize = 8192
    let hopSize = 2048
    let s = MonitoringSession(sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)
    s.band = .bassSubwoofer

    let windowCount = 300
    let totalSamples = fftSize + (windowCount - 1) * hopSize
    let freq = 55.0
    let amplitude: Float = 0.5
    let fullSine = (0..<totalSamples).map {
        amplitude * Float(sin(2.0 * .pi * freq * Double($0) / sampleRate))
    }

    // Deterministic pseudo-random jitter, roughly uncorrelated tick-to-tick
    // (unlike a smooth sinusoid, whose consecutive values barely differ) --
    // this is what makes it a faithful stand-in for real `Task.sleep`
    // scheduler drift, where one tick's overshoot has nothing to do with the
    // next tick's.
    func pseudoJitter(_ i: Int) -> Double {
        var x = UInt64(i &+ 1)
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27
        x = x &* 0x2545F4914F6CDD1D
        let frac = Double(x % 1_000_000) / 1_000_000.0   // [0, 1)
        return (frac - 0.5) * 0.004   // +/- 2ms
    }

    let idealDt = Double(hopSize) / sampleRate
    var t = 0.0
    for i in 0..<windowCount {
        let start = i * hopSize
        let window = Array(fullSine[start..<(start + fftSize)])
        s.ingestForTesting(samples: window, at: t + pseudoJitter(i))
        t += idealDt
    }

    // No duplication, no loss: exactly the real audio fed in must be recorded.
    #expect(s.recordedSampleCountForTesting == totalSamples)

    let recorded = s.filteredBufferLatestForTesting(totalSamples)
    #expect(recorded.count == totalSamples)

    // 3-point linear-prediction residual: a clean (filtered) sine predicts
    // its next sample almost exactly from its previous two; a splice
    // (duplicated or skipped samples) breaks that prediction hard, right at
    // the splice point.
    var residuals = [Float]()
    residuals.reserveCapacity(recorded.count - 2)
    for i in 2..<recorded.count {
        let predicted = 2 * recorded[i - 1] - recorded[i - 2]
        residuals.append(abs(recorded[i] - predicted))
    }
    let average = residuals.reduce(0, +) / Float(residuals.count)
    let maxResidual = residuals.max() ?? 0
    let maxIndex = residuals.firstIndex(of: maxResidual) ?? -1

    #expect(average > 0)   // sanity: the signal isn't flat silence
    #expect(maxResidual < average * 5,
            "residual spike \(maxResidual) at sample \(maxIndex) vs average \(average) -- looks spliced")
}

// MARK: - Monitoring span lifecycle driven end-to-end through the session (Task 4)
//
// Task 3 wired `RecordingCoordinator.start`/`stop`/`heartbeatSpan` and unit-tested
// the 30s-rolling behavior directly on the coordinator
// (`testHeartbeatRollsEndedAtForward`). This test instead goes through the real
// `MonitoringSession` start -> ingest -> shutdown path (via `startRecordingForTesting`,
// same seam as the C1/C2/I3 tests above) to verify the session actually opens and
// finalizes a span, without depending on the 30s wall-clock heartbeat cadence itself
// (that would be slow/flaky here -- the poll interval is 1 Hz in production).

@MainActor
@Test func testMonitoringSessionOpensAndClosesASpan() async throws {
    let s = MonitoringSession()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwsession-\(UUID().uuidString)")
    await s.startRecordingForTesting(root: root)

    let quiet = [Float](repeating: 0, count: 8192)
    var t = 0.0
    for _ in 0..<20 { s.ingestForTesting(samples: quiet, at: t); t += 0.05 }

    await s.shutdown()
    #expect(s.isRunning == false)

    let store = try EventStore(url: RecordingPaths(root: root).databaseURL)
    let spans = try store.spans(from: Date(timeIntervalSince1970: 0),
                                to: Date(timeIntervalSince1970: 4_000_000_000))
    store.close()
    #expect(spans.count == 1)
    #expect(spans[0].endedAt >= spans[0].startedAt)
}

@MainActor
@Test func testTriggerThresholdDefaultsToMinus35AndPersistsUserChanges() {
    let defaults = UserDefaults(suiteName: "bw-test-\(UUID().uuidString)")!
    // Fresh install: the default trigger threshold is -35 dBFS.
    let s1 = MonitoringSession(defaults: defaults)
    #expect(MonitoringSession.defaultTriggerDBFS == -35)
    #expect(s1.detectorConfig.triggerDBFS == -35)

    // A user threshold change is remembered as the future default...
    s1.setTriggerThreshold(-28)
    #expect(s1.detectorConfig.triggerDBFS == -28)
    let s2 = MonitoringSession(defaults: defaults)
    #expect(s2.detectorConfig.triggerDBFS == -28)

    // ...but setting detectorConfig directly (internal/tests) does NOT persist.
    s2.detectorConfig = DetectorConfig(triggerDBFS: -50)
    let s3 = MonitoringSession(defaults: defaults)
    #expect(s3.detectorConfig.triggerDBFS == -28)
}

// MARK: - Task 2: session ownership (`startedBySchedule`)
//
// The scheduler (a later task) must stop only sessions IT started, never a
// manually-started one. `startedBySchedule` is how a session records who
// started it: set on a successful `start(bySchedule:)`/
// `startRecordingForTesting(root:bySchedule:)`, cleared on every teardown.
// Driven through the no-mic `startRecordingForTesting` seam, like the C1/C2/I3
// tests above, since a real `start()` needs a granted mic.

@MainActor
@Test func testStartedByScheduleFlagTracksOwnership() async {
    let s = MonitoringSession(defaults: UserDefaults(suiteName: "bw-\(UUID().uuidString)")!)
    #expect(s.startedBySchedule == false)
    await s.startRecordingForTesting(root: tempRoot(), bySchedule: true)
    #expect(s.isRunning)
    #expect(s.startedBySchedule == true)         // scheduler-owned
    s.stop()
    #expect(s.startedBySchedule == false)        // cleared on stop
    await s.startRecordingForTesting(root: tempRoot(), bySchedule: false)
    #expect(s.startedBySchedule == false)        // manual-owned
    s.stop()
}

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - Task 2: proactive low-disk warning (banner + notification)
//
// `handleRecordingStatusPoll(_:)` is the exact per-poll decision
// `recordingStatusTask` makes every tick (see its doc comment) -- exposed
// directly, mirroring `processLoopIteration(now:)`'s seam for the
// stall/no-signal detectors, so the notify-once/re-arm-on-recovery logic can
// be driven deterministically with synthetic `RecordingStatus` values instead
// of needing real free disk space or a live 1 Hz timer.

@MainActor
private final class FakeNotifier: UserNotifying {
    private(set) var posts: [(title: String, body: String, id: String)] = []
    private var postedIDs: Set<String> = []
    func requestAuthorization() async {}
    func post(title: String, body: String, id: String) {
        guard postedIDs.insert(id).inserted else { return }
        posts.append((title: title, body: body, id: id))
    }
}

private func lowDiskStatus(freeBytes: Int64 = 5_000_000_000) -> RecordingStatus {
    RecordingStatus(isRecording: true, eventsWritten: 0, lastError: nil,
                    freeBytes: freeBytes, isLowOnDisk: true)
}

private func healthyDiskStatus(freeBytes: Int64 = 50_000_000_000) -> RecordingStatus {
    RecordingStatus(isRecording: true, eventsWritten: 0, lastError: nil,
                    freeBytes: freeBytes, isLowOnDisk: false)
}

@MainActor
@Test func testHandleRecordingStatusPollPublishesStatusRegardlessOfDiskLevel() {
    let s = MonitoringSession()
    let status = healthyDiskStatus()
    s.handleRecordingStatusPoll(status)
    #expect(s.recordingStatus == status)
}

@MainActor
@Test func testLowDiskNotifiesOnceThenSuppressesRepeatsWhileStillLow() {
    let notifier = FakeNotifier()
    let s = MonitoringSession(notifier: notifier)

    s.handleRecordingStatusPoll(lowDiskStatus())
    #expect(notifier.posts.count == 1)

    // Several more ticks, still low -- must NOT spam a post per tick.
    s.handleRecordingStatusPoll(lowDiskStatus())
    s.handleRecordingStatusPoll(lowDiskStatus())
    #expect(notifier.posts.count == 1)
}

@MainActor
@Test func testLowDiskReArmsAfterRecoveryAndReNotifiesUnderADistinctID() {
    let notifier = FakeNotifier()
    let s = MonitoringSession(notifier: notifier)

    s.handleRecordingStatusPoll(lowDiskStatus())
    #expect(notifier.posts.count == 1)
    let firstID = notifier.posts[0].id

    // Disk recovers -- re-arms the dedupe flag, but posts nothing itself.
    s.handleRecordingStatusPoll(healthyDiskStatus())
    #expect(notifier.posts.count == 1)

    // Low again: a NEW episode, so it must alert again, under a fresh id --
    // otherwise `SystemUserNotifier`'s permanent per-id dedupe would silently
    // swallow this second, genuinely new warning.
    s.handleRecordingStatusPoll(lowDiskStatus())
    #expect(notifier.posts.count == 2)
    #expect(notifier.posts[1].id != firstID)
}

@MainActor
@Test func testLowDiskNotificationNamesFreeSpace() {
    let notifier = FakeNotifier()
    let s = MonitoringSession(notifier: notifier)

    s.handleRecordingStatusPoll(lowDiskStatus(freeBytes: 5_500_000_000))   // ~5.1 GB

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].title == "Bandwatch — low disk space")
    #expect(notifier.posts[0].body.contains("5.1 GB"))
}

@MainActor
@Test func testStoppingSessionResetsLowDiskReArmSoTheNextSessionAlertsAgain() async {
    let notifier = FakeNotifier()
    let s = MonitoringSession(notifier: notifier)

    // First session goes low on disk and notifies.
    await s.startRecordingForTesting(root: tempRoot(),
                                     policy: RetentionPolicy(diskWarningBytes: Int64.max))
    await waitUntilTrue { notifier.posts.count == 1 }
    #expect(notifier.posts.count == 1)
    let firstID = notifier.posts[0].id

    s.stop()

    // A second session, ALSO starting out low on disk, must not be silently
    // suppressed by re-arm state left over from before the first session
    // stopped -- it gets its own fresh episode (and therefore its own id).
    await s.startRecordingForTesting(root: tempRoot(),
                                     policy: RetentionPolicy(diskWarningBytes: Int64.max))
    await waitUntilTrue { notifier.posts.count == 2 }
    #expect(notifier.posts.count == 2)
    #expect(notifier.posts[1].id != firstID)

    s.stop()
}
