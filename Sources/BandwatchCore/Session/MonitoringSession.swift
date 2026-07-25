import Foundation
import Observation

extension UserDefaults {
    /// Explicit preferences domain for Bandwatch settings, so they persist the
    /// same whether the app runs as a bundle (`open Bandwatch.app`) or as a bare
    /// binary (`swift run Bandwatch`). A bare binary has no bundle identifier, so
    /// `.standard` writes to a volatile domain that doesn't survive relaunch —
    /// which is why an input picked under `swift run` appeared not to persist.
    nonisolated(unsafe) public static let bandwatch =
        UserDefaults(suiteName: "com.bandwatch.Bandwatch.prefs") ?? .standard
}

/// Whether the input signal itself looks alive, independent of whether
/// capture is technically running. A stalled ring buffer (see
/// `captureStallThreshold` below) means no samples are arriving at all --
/// `.noSignal` is the opposite failure: samples ARE arriving, on schedule,
/// but they carry no real audio, because the signal path upstream of the
/// microphone tap is dead (interface muted, mixer off, cable pulled). Both
/// are needed; neither substitutes for the other.
public enum InputHealth: Equatable, Sendable {
    case healthy
    /// The input has been at or near digital silence long enough that a dead
    /// signal path is far more likely than a genuinely silent room.
    case noSignal
}

/// Whether capture is currently connected to its pinned device, or paused
/// waiting for that device to return. Distinct from `lastError` (which halts):
/// this is a recoverable, ongoing condition — the session stays `isRunning`.
public enum CaptureConnection: Equatable, Sendable {
    case connected
    case awaitingReconnect(deviceName: String)
}

/// Orchestrates capture, analysis, and detection, publishing observable state
/// for the UI. Owns no DSP logic of its own.
@MainActor
@Observable
public final class MonitoringSession {
    public static let levelHistoryCapacity = 1800
    private static let recentEventsCapacity = 100

    /// A live microphone in a real room does not read below this. Room ambient is
    /// typically -70 to -50 dBFS, so a sustained level here means the signal path
    /// is dead (interface muted, mixer off, cable pulled), not a quiet room.
    public static let noSignalThresholdDBFS: Double = -90.0

    /// How long the level must stay below the threshold before reporting no signal.
    /// Long enough not to trip on a genuine pause, short enough to catch a dead
    /// input early in an overnight run.
    public static let noSignalDuration: TimeInterval = 30.0

    /// How often the fast-changing display state -- `latestFrame` (the
    /// spectrum) and `levelHistory` -- is actually published to SwiftUI,
    /// versus the ~21.5 Hz analysis rate at which it is computed. Profiling a
    /// 30-minute run found the DSP pipeline itself costs 0.007 ms/frame --
    /// negligible -- while CPU was dominated by SwiftUI view-graph layout,
    /// because every analysis frame invalidated and re-laid-out the entire
    /// view tree. 12 Hz is ample for human perception of a scrolling chart (a
    /// human cannot perceive the difference between 12 Hz and 21.5 Hz
    /// updates) while roughly halving the number of layout passes versus
    /// publishing at the full analysis rate. Analysis itself -- the
    /// detector, baseline, and smoother -- is NEVER throttled: only what gets
    /// published to the observed properties that drive the UI.
    public static let displayInterval: TimeInterval = 1.0 / 12.0

    // MARK: Observable state

    public private(set) var latestFrame: AnalysisFrame?
    public private(set) var levelHistory: [Double] = []
    public private(set) var detectorState: DetectorState = .idle
    public private(set) var recentEvents: [DetectedEvent] = []
    public private(set) var suggestedThresholdDBFS: Double?
    public private(set) var isRunning = false
    /// True while a session the SCHEDULER started is running. The scheduler stops
    /// only sessions it owns (this true), never a manually-started one. Set by
    /// whoever starts the session (see `start(bySchedule:)`), cleared on every
    /// teardown. NOT reset by `resumeAfterReconnect` — ownership survives a
    /// device reconnect within the same session.
    public private(set) var startedBySchedule = false
    public private(set) var lastError: CaptureError?
    /// Distinct from `lastError`: this is a recoverable, ongoing condition --
    /// samples are still flowing and monitoring is NOT halted -- not a
    /// capture failure. Never feed it into `lastError`, which would make the
    /// error banner lie about capture having failed.
    public private(set) var inputHealth: InputHealth = .healthy
    public private(set) var captureConnection: CaptureConnection = .connected

    public static let preRollSeconds: TimeInterval = 10

    public private(set) var recordingStatus: RecordingStatus?
    public var isRecordingEnabled: Bool = true

    /// Root directory recorded audio and the database live under. `nil` (the
    /// default) means `RecordingPaths.defaultRoot()` — the real production
    /// location under `~/Library/Application Support/Bandwatch`.
    ///
    /// This exists so the destination is injectable rather than hardcoded:
    /// any test that calls `start()` with `isRecordingEnabled` left `true`
    /// must set this to a temporary directory, or it will create and write
    /// to the user's real evidence database. Tests that don't need recording
    /// should instead set `isRecordingEnabled = false` — both exist as
    /// belt-and-braces so neither one alone being forgotten can reach the
    /// production path.
    public var recordingRoot: URL?

    /// Whether to write the continuous band-filtered archive.
    ///
    /// DEFAULT false — see the "CLIPS ONLY" decision in the design spec. The
    /// archive costs ~52.4 MB/hour measured on real audio (~37 GB/month) versus
    /// ~13 MB/night for event clips, and the use case does not need it. The code
    /// is retained, not deleted, so the capability can be switched back on without
    /// rebuilding it.
    ///
    /// Event clips, the event log, and gap logging are UNAFFECTED by this flag.
    public var isContinuousArchiveEnabled: Bool = false

    /// Windows of filtered archive audio dropped because the bounded archive
    /// stream's buffer was full when they were produced (a stalled disk).
    /// Every dropped window is lost audio and must be visible, not silent —
    /// mirrors how `RecordingStatus.discardedStubCount`/`discardedFrames`
    /// already surface `SegmentWriter`'s own discards rather than dropping
    /// them unreported.
    ///
    /// Stays at 0 for the whole session when `isContinuousArchiveEnabled` is
    /// false: no archive stream is ever created, so nothing can be dropped
    /// from it — this must never carry over a stale nonzero value from a
    /// previous, archive-enabled session either, which is why `start()` and
    /// `startRecordingForTesting` both reset it unconditionally.
    public private(set) var droppedArchiveWindowCount = 0

    /// Test-only visibility into the filtered audio that would be recorded.
    /// `@ObservationIgnored`: this is reassigned an ~8192-element array on
    /// every analysis window (~21.5 Hz) purely for test inspection, and an
    /// `@Observable` class fires observation bookkeeping on every mutation of
    /// a tracked stored property. `workingFrame`/`workingLevelHistory` are
    /// ignored for the identical reason — see the M1–M2 cost documented on
    /// them (CPU ~36% -> ~8%). Nothing here is ever read by SwiftUI, so there
    /// is nothing to observe.
    @ObservationIgnored public private(set) var lastFilteredSamplesForTesting: [Float]?
    public var filteredBufferCapacityForTesting: Int { filteredBuffer.capacity }

    /// Test-only running total of samples actually handed to the filter +
    /// `filteredBuffer` + archive-stream recording path this session (i.e.
    /// AFTER the overlap-dedup fix below, never the full overlapping
    /// analysis window). Pins the recording path to consuming each sample
    /// of arrived audio exactly once: before the fix this would have
    /// accumulated at up to 4x the real arrival rate (`fftSize`/`hopSize`
    /// == 4), since every 75%-overlapping window was filtered and written
    /// in full. `@ObservationIgnored` for the same reason as the property
    /// above -- nothing here is ever read by SwiftUI.
    @ObservationIgnored public private(set) var recordedSampleCountForTesting: Int = 0

    /// Test-only peek into `filteredBuffer`'s accumulated content -- lets a
    /// test confirm the buffer holds a real, contiguous span of audio (not
    /// a duplicated/compressed one) by requesting the same
    /// `preRoll + duration + release` span an event clip would.
    public func filteredArchiveLatestForTesting(_ count: Int) -> [Float] {
        filteredBuffer.latest(count)
    }

    public var band: FrequencyBand {
        didSet {
            guard band != oldValue else { return }
            filter = BandFilter(band: band, sampleRate: sampleRate)
            baseline.reset()
            suggestedThresholdDBFS = nil
            levelHistory.removeAll()
            detector.reset()
            detectorState = detector.state
            // The smoother's running value is a smoothed power derived from
            // the OLD band's level signal; it means nothing under the new
            // band, so it must be reset alongside baseline/detector.
            levelSmoother.reset()
            // The stale frame was computed under the OLD band; leaving it
            // published would show the UI an inconsistent spectrum/shaded
            // region pairing, indefinitely if the session isn't running.
            latestFrame = nil
            // The no-signal timer and verdict are meaningless across a band
            // change -- a band swap is not evidence the signal path died.
            noSignalStartTime = nil
            inputHealth = .healthy
            // The working copies mirror what was just cleared above; without
            // resetting them too, the next display publish would resurrect
            // the old band's stale frame/history/suggestion. Resetting the
            // publish timer makes that next frame publish immediately rather
            // than waiting out a stale displayInterval window.
            workingFrame = nil
            workingLevelHistory.removeAll()
            lastPublishTime = nil
        }
    }

    /// IEC-style response speed for the level fed to the detector/history/UI.
    /// Purely a display/response preference: changing it does NOT reset the
    /// smoother's running value, the baseline, or the detector -- it is not a
    /// re-tuning of the band being monitored. See LevelSmoother for why this
    /// only affects the attack side, not the release side.
    public var timeWeighting: TimeWeighting {
        get { levelSmoother.weighting }
        set { levelSmoother.weighting = newValue }
    }

    public var detectorConfig: DetectorConfig {
        didSet {
            detector.config = detectorConfig
            // EventDetector.config's own didSet calls reset() when the value
            // actually changes, which can flip the detector's real state
            // (e.g. out of .candidate/.recording) without any further
            // ingestion to refresh the published property. Re-sync here so
            // the UI never renders an event that the detector has already
            // discarded.
            detectorState = detector.state
        }
    }

    // MARK: Display publish throttling
    //
    // These mirror `latestFrame` and `levelHistory` but are
    // `@ObservationIgnored`, so mutating them every analysis frame does NOT
    // invalidate any SwiftUI view. `processWindow` updates these
    // unconditionally, every frame, then copies them into the observed
    // properties only once `displayInterval` has elapsed -- see
    // `publishDisplayStateIfDue(at:)`. Analysis itself (detector, baseline,
    // smoother) reads directly from the per-frame `level`/`magnitudes`
    // locals in `processWindow`, never from these, so none of it is
    // throttled. `suggestedThresholdDBFS` is a single `Double?` -- cheap
    // enough to publish immediately alongside the state-transition
    // properties below, rather than through this mechanism.
    @ObservationIgnored private var workingFrame: AnalysisFrame?
    @ObservationIgnored private var workingLevelHistory: [Double] = []
    @ObservationIgnored private var lastPublishTime: TimeInterval?

    // MARK: Internals

    private let sampleRate: Double
    private let fftSize: Int
    private let hopSize: Int

    private let ringBuffer: RingBuffer
    private let analyzer: SpectrumAnalyzer
    private let meter: BandLevelMeter
    // Band level is computed from FFT magnitudes (via `meter`), not filtered
    // audio — the two paths are deliberately independent. `filter.process(...)`
    // is called once per window purely to produce the audio that gets
    // recorded (see `processWindow`); it never feeds the level/detector path.
    private var filter: BandFilter
    private let detector: EventDetector
    private let baseline = BaselineEstimator()
    private let levelSmoother: LevelSmoother
    private var capture: AudioCaptureEngine?

    /// This process's launch time (this object is created once, at app launch).
    /// Passed to the `RecordingCoordinator` so it only auto-resolves coverage
    /// gaps a PRIOR run left open — never one the current session is managing.
    @ObservationIgnored private let launchTime = Date()

    // MARK: Recording
    //
    // `filteredBuffer` holds band-filtered audio only — this is the ONLY
    // audio that ever reaches disk. Sized for the worst-case clip
    // (preRoll + maximumDuration + releaseTime), not an arbitrary 30s: a
    // smaller buffer would silently truncate the pre-roll on a long event.
    // `coordinator` owns all disk I/O and is an actor precisely so its calls
    // (always `await`ed from a detached `Task`) can never block
    // `processWindow`, which must stay synchronous and fast on the main
    // actor alongside the UI.
    @ObservationIgnored private let filteredBuffer: RingBuffer
    @ObservationIgnored private var coordinator: RecordingCoordinator?
    @ObservationIgnored private var captureStalledGapOpen = false
    @ObservationIgnored private var noSignalGapOpen = false
    @ObservationIgnored private var deviceDisconnectGapOpen = false

    /// `ringBuffer.totalWritten` as of the last time the recording path
    /// consumed audio, `nil` until the first window of a session.
    /// `processWindow`'s incoming `samples` is always the full `fftSize`
    /// analysis window, which overlaps 75% with the previous call
    /// (`hopSize` == `fftSize`/4) -- recording the whole thing every call is
    /// the M3 duplication bug (measured: up to 4x real time, with the
    /// archive stream then dropping enough of that to land at 1.86x on a
    /// real session). This marker is what lets `processWindow` compute
    /// exactly how much of `samples` is genuinely new since the last pass
    /// and record only that.
    ///
    /// Keyed to `ringBuffer.totalWritten` (the capture ring buffer's
    /// monotonic count of every sample the capture thread has ever
    /// delivered), NOT to elapsed `time` as this used to be. The live
    /// analysis loop is driven by `Task.sleep`, which jitters by a
    /// millisecond or two per tick -- a `time`-derived count does not tile
    /// the arriving sample stream exactly under that jitter, so every
    /// window boundary either re-recorded a few already-recorded samples or
    /// skipped a few that never got recorded: both are splices, and both
    /// click (the M3.6 splice bug). `totalWritten` counts real delivered
    /// samples, so consecutive reads of it tile the stream exactly
    /// regardless of loop jitter.
    ///
    /// `ingestForTesting` -- which the large majority of this file's tests
    /// drive `processWindow` through -- writes its samples into
    /// `ringBuffer` before calling `processWindow` (see that method's doc
    /// comment), so `totalWritten` genuinely advances under test exactly as
    /// it would under live capture, and this counter means the same thing
    /// on both paths.
    @ObservationIgnored private var lastConsumedTotal: Int?

    /// Polls `coordinator.status()` at a low, fixed rate and publishes it to
    /// `recordingStatus` -- deliberately NOT driven from `processWindow`.
    /// Recording status (write failures, free space, open gaps) changes
    /// slowly; coupling it to the ~21.5 Hz analysis rate would re-introduce
    /// exactly the per-frame SwiftUI cost the `displayInterval` throttle
    /// above exists to avoid. Torn down (cancelled and re-nilled) alongside
    /// `archiveContinuation`/`archiveConsumerTask` in both `stop()` and
    /// `failCaptureStalled(at:)`, for the same reason those are: leaving it
    /// running after its `coordinator` is gone would let a stale task from a
    /// finished session keep overwriting `recordingStatus` with a defunct
    /// coordinator's readings, potentially racing a NEW session's own
    /// polling task after a stop() -> start() cycle.
    @ObservationIgnored private var recordingStatusTask: Task<Void, Never>?
    /// How often `recordingStatusTask` polls. 1 Hz is ample: recording
    /// health is monotonic/slow-changing, unlike the spectrum/level display.
    private static let recordingStatusPollInterval: Duration = .seconds(1)
    /// Heartbeat the monitoring span every 30 polls. At the 1 Hz poll rate that is
    /// ~30 s -- the worst-case coverage lost if the app crashes mid-session, always
    /// in the under-reporting (never overstating) direction. See the spec.
    private static let heartbeatPollCount = 30

    // MARK: Archive audio delivery (bounded, backpressured)
    //
    // `processWindow` must stay synchronous and never `await`, so it cannot
    // hand filtered audio to the `coordinator` actor directly. Previously it
    // spawned a `Task` per window; ordering was safe (main-actor tasks at
    // equal priority run in enqueue order) but there was no backpressure —
    // if the disk stalled, tasks would pile up unboundedly, each retaining an
    // ~8192-element `[Float]`. An `AsyncStream` with a bounded, dropping
    // buffering policy fixes this: `yield` is synchronous and non-blocking,
    // and a stalled consumer drops the OLDEST buffered windows rather than
    // growing without limit. Event clips are NOT sent through this stream —
    // they stay on their own per-event `Task` (see `processWindow`) because
    // they are rare and must never be dropped.
    private struct ArchiveChunk: Sendable {
        let samples: [Float]
        let wallClock: Date
    }
    // ~64 windows at the ~46.4ms real hop interval is ~3s of buffered audio
    // -- a few seconds' grace for a momentary disk stall before windows
    // start being dropped, without letting an indefinitely stalled disk
    // accumulate audio without bound.
    //
    // This whole subsystem — the stream, its continuation, and the consumer
    // Task that drains it into `coordinator.appendArchive` — is only stood
    // up in `start()`/`startRecordingForTesting` when
    // `isContinuousArchiveEnabled` is true. With it false (the default, per
    // the "CLIPS ONLY" decision), `archiveContinuation` stays nil for the
    // whole session: `processWindow`'s `if ... let archiveContinuation`
    // guard below then simply never fires, so no archive segment is ever
    // created and `droppedArchiveWindowCount` never leaves 0. Event clips are
    // unaffected either way — they read from `filteredBuffer`, which
    // `processWindow` fills unconditionally regardless of this flag.
    private static let archiveStreamBufferCount = 64
    @ObservationIgnored private var archiveContinuation: AsyncStream<ArchiveChunk>.Continuation?
    @ObservationIgnored private var archiveConsumerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    // Detection timing runs on this rather than wall-clock time: an NTP
    // correction must not be able to stall an event's release (backwards
    // step) or instantly trip maximumDuration (forwards step). Wall-clock
    // time is reserved for values later written to disk as permanent
    // evidence -- file names, segment boundaries, event row timestamps --
    // none of which exist on this path yet.
    @ObservationIgnored private var clock = MonotonicClock()
    // Guards against a stop() -> start() cycle racing the previous loop's
    // cancellation. stop() cancels analysisTask and flips isRunning false;
    // start() can then flip isRunning back true before the OLD task's
    // suspended `try? await Task.sleep` continuation gets scheduled to
    // resume. Both tasks are MainActor-isolated, so there's no data race —
    // but when that continuation does resume, `try?` swallows the
    // CancellationError from the sleep, and the guard below would see
    // isRunning == true (set by the NEW start()) and let the OLD task
    // process one spurious window — a stray levelHistory append and
    // detector.process() call — before Task.isCancelled is finally
    // observed on its next iteration. start() bumps this counter on every
    // call; each loop iteration checks the generation it was created with
    // against the current one, so a stale task from a prior start()
    // recognizes itself as superseded and exits immediately instead of
    // relying on isRunning alone.
    private var analysisGeneration = 0

    // MARK: Staleness / stall detection
    //
    // The loop wakes on a timer regardless of whether new audio actually
    // arrived. `AudioCaptureEngine` has no path to report a mid-capture
    // failure (device disconnect, converter failure) — see its doc comment —
    // so if the tap goes silent, `ringBuffer.latest(fftSize)` would otherwise
    // keep returning the same frozen window forever, and the session would
    // keep publishing fresh timestamps against a dead signal: the UI stays
    // green, and a frozen level sitting above the trigger fabricates events
    // all night from a microphone that isn't there. `totalWritten` is the
    // only reliable signal that real audio moved through the buffer.
    private var lastObservedTotalWritten = 0
    private var stallStartTime: TimeInterval?
    // How long the ring buffer may go without advancing before capture is
    // declared failed. 3 seconds is comfortably above normal Task.sleep /
    // scheduler jitter (which is sub-hop, i.e. well under 100ms) so it will
    // not false-trigger under ordinary load, but short enough that an
    // unattended overnight run doesn't waste hours analyzing — or emitting
    // fabricated events from — a dead input.
    private static let captureStallThreshold: TimeInterval = 3.0

    // MARK: Input health (dead signal path) detection
    //
    // The timestamp at which the level most recently dropped to (or below)
    // noSignalThresholdDBFS, nil while healthy. Tracked separately from
    // stallStartTime: this is about the CONTENT of samples that are arriving
    // on schedule, not about whether samples are arriving at all.
    private var noSignalStartTime: TimeInterval?

    // MARK: Input device selection

    /// The *effective* chosen input device UID, or nil to follow the system
    /// default. Bound to the picker. Setting it from the UI persists the choice;
    /// internal re-resolution (`resolveInputSelection`) does not. It may
    /// transiently fall back to nil when the preferred device isn't present yet
    /// (e.g. not enumerated at early launch), and recover on the next refresh.
    public var selectedInputDeviceUID: String? {
        didSet {
            // Only user/picker changes persist and update the remembered
            // preference; a resolve-driven change must not clobber it.
            guard !isResolvingInput, selectedInputDeviceUID != oldValue else { return }
            persistedInputUID = selectedInputDeviceUID
            if let uid = selectedInputDeviceUID {
                defaults.set(uid, forKey: Self.inputDeviceDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.inputDeviceDefaultsKey)
            }
        }
    }
    /// Current input devices, for the picker. Refresh with `refreshInputDevices()`.
    public private(set) var availableInputDevices: [AudioInputDevice] = []
    /// One-line notice when the remembered device is currently unavailable.
    public internal(set) var inputNotice: String?

    @ObservationIgnored private let deviceEnumerator: InputDeviceEnumerating
    @ObservationIgnored private let defaults: UserDefaults
    /// The remembered preference (source of truth for re-resolution): the UID the
    /// user last chose, or nil for System Default. Distinct from the *effective*
    /// `selectedInputDeviceUID`, which can transiently differ when the preferred
    /// device isn't currently enumerated.
    @ObservationIgnored private var persistedInputUID: String?
    @ObservationIgnored private var isResolvingInput = false
    static let inputDeviceDefaultsKey = "bandwatch.selectedInputDeviceUID"
    static let thresholdDefaultsKey = "bandwatch.triggerDBFS"
    /// The detector trigger threshold used until the user sets their own (which
    /// then becomes the remembered default — see `setTriggerThreshold`).
    public static let defaultTriggerDBFS: Double = -35

    // (see `UserDefaults.bandwatch` at file scope for why settings use an
    // explicit domain rather than `.standard`.)

    /// Re-reads available devices and re-resolves the selection against them.
    /// Safe to call repeatedly (the picker calls it on appear) — this is how a
    /// device that wasn't enumerated at early app launch, or one just plugged
    /// in, gets selected once it appears.
    public func refreshInputDevices() {
        availableInputDevices = deviceEnumerator.available()
        resolveInputSelection()
    }

    enum DeviceChangeAction: Equatable {
        case refreshOnly
        case pause(deviceName: String)
        case resume
    }

    /// Pure decision from current state + the freshly-read device list.
    /// `devices` is the just-enumerated list -- the caller assigns it to
    /// `availableInputDevices` in every branch immediately afterward, but
    /// passes it here first so this decision (and, on the `.pause` path,
    /// `pinnedDeviceName`'s lookup of the departing device's name in the
    /// still-stale `availableInputDevices`) sees the two lists distinctly.
    /// Pinned-only: a nil `persistedInputUID` (System Default) never pauses.
    func deviceChangeAction(devices: [AudioInputDevice]) -> DeviceChangeAction {
        guard isRunning, let pinned = persistedInputUID else { return .refreshOnly }
        let present = devices.contains { $0.uid == pinned }
        switch captureConnection {
        case .connected:
            return present ? .refreshOnly : .pause(deviceName: pinnedDeviceName(pinned))
        case .awaitingReconnect:
            return present ? .resume : .refreshOnly
        }
    }

    /// Best-known display name for the pinned UID: the last-seen name from the
    /// current list, falling back to the UID itself if it is already gone.
    private func pinnedDeviceName(_ uid: String) -> String {
        availableInputDevices.first { $0.uid == uid }?.name ?? uid
    }

    /// Reacts to a Core Audio hardware-topology change. Refreshes the device
    /// list so the picker stays current, and -- for a session that is running
    /// with a pinned (non-System-Default) input -- pauses capture when that
    /// device disconnects, and resumes it when the device returns.
    func handleDeviceChange() {
        // Read the fresh list FIRST so the pause/resume decision reflects
        // whether the pinned device is present RIGHT NOW -- deviceChangeAction
        // takes it as an explicit parameter for exactly this reason. Crucially,
        // this is done before `availableInputDevices` itself is reassigned
        // below, so pinnedDeviceName (called from inside deviceChangeAction,
        // on the .pause path) still reads the PRE-refresh list and can find
        // the departing device's name one last time.
        let fresh = deviceEnumerator.available()
        let action = deviceChangeAction(devices: fresh)
        switch action {
        case .refreshOnly:
            availableInputDevices = fresh
            // Re-resolve the pinned selection when stopped, so a pinned device that
            // reconnects while monitoring is stopped gets re-selected (otherwise Start
            // would silently fall back to System Default / the built-in mic). NOT while
            // running/awaiting: resolveInputSelection() would clear selectedInputDeviceUID
            // during awaitingReconnect and break resumeAfterReconnect's UID lookup.
            if !isRunning { resolveInputSelection() }
        case .pause(let name):
            availableInputDevices = fresh
            pauseForDisconnect(deviceName: name)
        case .resume:
            availableInputDevices = fresh
            resumeAfterReconnect()
        }
    }

    /// Pinned device vanished mid-session: tear down capture (so AUHAL's silent
    /// fallback to the built-in mic can never reach the detector/recorder),
    /// open a coverage gap, and enter the paused/awaiting state. The session
    /// stays `isRunning`; the coordinator stays alive.
    private func pauseForDisconnect(deviceName: String) {
        analysisTask?.cancel()
        analysisTask = nil
        capture?.stop()
        capture = nil
        latestFrame = nil
        captureConnection = .awaitingReconnect(deviceName: deviceName)
        if !deviceDisconnectGapOpen, let c = coordinator {
            deviceDisconnectGapOpen = true
            let wall = Date()
            Task { await c.openGap(reason: .deviceLost, at: wall) }
        }
    }

    /// Same pinned device returned: close the gap and restart capture on it.
    /// The coordinator stayed alive, so no permission prompt or new session.
    private func resumeAfterReconnect() {
        closeDeviceDisconnectGap()
        captureConnection = .connected
        do {
            try startCapture(targetDeviceUID: selectedInputDeviceUID)
        } catch {
            // The device returned but the engine would not restart on it. Halt like a
            // genuine capture failure -- stop() tears down the still-live coordinator
            // (open segment, SQLite handle, polling task) that pause left running,
            // instead of orphaning it (see failCaptureStalled's note on this bug class).
            // isRunning is still true here (startCapture throws before setting it), so
            // stop()'s `guard isRunning` passes and the full teardown runs.
            stop()
            lastError = (error as? CaptureError) ?? .engineStartFailed(error.localizedDescription)
        }
    }

    private func closeDeviceDisconnectGap() {
        guard deviceDisconnectGapOpen, let c = coordinator else { return }
        deviceDisconnectGapOpen = false
        let wall = Date()
        Task { await c.closeGap(reason: .deviceLost, at: wall) }
    }

    /// Test seam: the resume analog of `startRecordingForTesting`. Performs the
    /// logical half of resume (close the gap, return to `.connected`) WITHOUT
    /// bringing up a real `AVAudioEngine`, which needs a microphone unavailable
    /// in CI. The real engine restart is covered manually (Task 5).
    func resumeForTesting() {
        closeDeviceDisconnectGap()
        captureConnection = .connected
    }

    /// Sets the effective selection from the remembered preference and the
    /// current device list, WITHOUT persisting (guarded by `isResolvingInput` so
    /// the didSet doesn't treat it as a user change and clobber the preference).
    private func resolveInputSelection() {
        isResolvingInput = true
        defer { isResolvingInput = false }
        guard let pref = persistedInputUID else {
            selectedInputDeviceUID = nil            // user chose System Default
            inputNotice = nil
            return
        }
        if availableInputDevices.contains(where: { $0.uid == pref }) {
            selectedInputDeviceUID = pref
            inputNotice = nil
        } else {
            selectedInputDeviceUID = nil            // fall back for now; keep the preference
            inputNotice = "Saved input device unavailable — using System Default."
        }
    }

    /// The device UID to stamp on recorded events: the selected device if it is
    /// currently present, otherwise the system default, otherwise the legacy
    /// placeholder. Derived from the enumerator so it stays honest about what
    /// actually captured.
    func recordingDeviceUID() -> String {
        if let uid = selectedInputDeviceUID,
           availableInputDevices.contains(where: { $0.uid == uid }) {
            return uid
        }
        return deviceEnumerator.systemDefaultUID() ?? "default"
    }

    public init(sampleRate: Double = 44100, fftSize: Int = 8192, hopSize: Int = 2048,
                deviceEnumerator: InputDeviceEnumerating = CoreAudioInputDevices(),
                defaults: UserDefaults = .bandwatch) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.deviceEnumerator = deviceEnumerator
        self.defaults = defaults

        guard let analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate) else {
            preconditionFailure("fftSize must be a power of two")
        }
        self.analyzer = analyzer
        self.meter = BandLevelMeter(analyzer: analyzer)

        let initialBand = FrequencyBand.bassSubwoofer
        self.band = initialBand
        self.filter = BandFilter(band: initialBand, sampleRate: sampleRate)

        // Start from the user's remembered threshold if they've set one,
        // otherwise the default. Persisted via `setTriggerThreshold`.
        let savedThreshold = defaults.object(forKey: Self.thresholdDefaultsKey) as? Double
        let config = DetectorConfig(triggerDBFS: savedThreshold ?? Self.defaultTriggerDBFS)
        self.detectorConfig = config
        self.detector = EventDetector(config: config)

        self.levelSmoother = LevelSmoother(weighting: .fast, hopInterval: Double(hopSize) / sampleRate)

        // 30 seconds of ring buffer, per spec.
        self.ringBuffer = RingBuffer(capacity: Int(sampleRate * 30))

        // A recorded clip spans preRoll + event duration + release time (see
        // processWindow's event-handling comment for why), and
        // maximumDuration defaults to 300s -- a 30-second buffer would
        // silently truncate the pre-roll on exactly the longest, most
        // significant events. At 44.1 kHz this is roughly 318s x 44100 x
        // 4 bytes = 56 MB, which is acceptable next to that alternative.
        let worstCaseSeconds = Self.preRollSeconds
            + config.maximumDuration
            + config.releaseTime
            + 5
        self.filteredBuffer = RingBuffer(capacity: Int(sampleRate * worstCaseSeconds))

        // Load the remembered preference and resolve it against the currently
        // enumerated devices. If the device list is empty/incomplete this early
        // in launch, resolution falls back to System Default WITHOUT clearing
        // the preference, and the picker's onAppear `refreshInputDevices()`
        // re-resolves once the list is ready (recovering the saved device).
        self.persistedInputUID = defaults.string(forKey: Self.inputDeviceDefaultsKey)
        self.availableInputDevices = deviceEnumerator.available()
        resolveInputSelection()

        // Live-refresh the picker (and, once running, detect a pinned device
        // disconnecting) on any hardware topology change. Delivered on the main
        // queue by CoreAudioInputDevices, so assumeIsolated is valid here.
        deviceEnumerator.startObserving { [weak self] in
            MainActor.assumeIsolated { self?.handleDeviceChange() }
        }
    }

    deinit { deviceEnumerator.stopObserving() }

    // MARK: Lifecycle

    /// Brings up the capture engine on `targetDeviceUID` (nil = system default)
    /// and starts the analysis loop. Shared by `start()` (fresh session) and
    /// `resumeAfterReconnect()` (same device returning). Passes the device
    /// *UID*, not a resolved `AudioDeviceID`: the engine re-resolves it on every
    /// (re)start, which is what keeps a reconnect working after the ID has gone
    /// stale. Throws the same `CaptureError`s `AudioCaptureEngine.start()` does.
    /// Does NOT touch permission, the coordinator, or session-state resets —
    /// those belong to the caller.
    private func startCapture(targetDeviceUID: String?) throws {
        // Start capture from a clean analysis state. For `start()` this repeats
        // its own reset block (harmless — the values are idempotent). For
        // `resumeAfterReconnect()` it is ESSENTIAL: without it the resumed
        // analysis loop inherits a `stallStartTime` set in the moments between
        // the physical unplug and `pauseForDisconnect` (when the tap had already
        // gone silent), so its very first post-resume tick computes "stalled for
        // several seconds" against that stale timestamp and trips the 3s stall
        // detector almost immediately — the reconnect never gets a chance to
        // recover. Clearing the ring/filter buffers also stops the first
        // post-resume window from being spliced across the monitoring gap.
        ringBuffer.clear()
        lastObservedTotalWritten = 0
        stallStartTime = nil
        levelSmoother.reset()
        filter.reset()
        filteredBuffer.clear()
        lastConsumedTotal = nil
        noSignalStartTime = nil
        inputHealth = .healthy
        lastPublishTime = nil

        let engine = AudioCaptureEngine(ringBuffer: ringBuffer, sampleRate: sampleRate,
                                        targetDeviceUID: targetDeviceUID)
        try engine.start()
        capture = engine
        isRunning = true
        analysisGeneration += 1
        startAnalysisLoop(generation: analysisGeneration)
    }

    public func start(bySchedule: Bool = false) async {
        guard !isRunning else { return }
        lastError = nil

        // The app never registers with TCC — and so never appears in System
        // Settings › Privacy & Security › Microphone for the user to grant
        // access — until it actually calls requestAccess(for:) at least
        // once. AudioCaptureEngine.start()'s own permission guard only
        // checks the current status; it never requests, so on first launch
        // (.undetermined) it would throw permissionDenied without macOS ever
        // having shown a prompt. Requesting here, before construction, is
        // what makes that prompt happen.
        switch AudioCaptureEngine.currentPermission() {
        case .granted:
            break
        case .undetermined:
            let granted = await AudioCaptureEngine.requestPermission()
            guard granted else {
                lastError = .permissionDenied
                return
            }
        case .denied:
            lastError = .permissionDenied
            return
        }

        // A stop() -> start() cycle must not analyze windows spliced across
        // the gap: without clearing, the first post-restart window mixes
        // pre-gap and post-gap audio, producing broadband splatter that can
        // spuriously trip the detector. Clearing also resets totalWritten to
        // 0, so the stall check below starts each run from a known-good
        // baseline instead of comparing against a stale high-water mark.
        ringBuffer.clear()
        lastObservedTotalWritten = 0
        stallStartTime = nil
        // A fresh Start gets a fresh monotonic origin -- detection timing
        // must not carry over gaps or elapsed time from a previous run.
        clock.reset()
        // A new session must not inherit the previous session's running
        // smoothed level -- otherwise the first frames after Start would be
        // pulled toward a stale value from before Stop.
        levelSmoother.reset()
        // Nor should it inherit a stale no-signal verdict/timer from before
        // Stop -- a fresh Start deserves a fresh assessment of the input.
        noSignalStartTime = nil
        inputHealth = .healthy
        // A fresh Start should publish its first frame immediately rather
        // than waiting out a leftover displayInterval window from before Stop.
        lastPublishTime = nil
        // A fresh Start must not analyze filtered audio spliced across the
        // gap, nor carry over the previous run's filter memory (see
        // BandFilter's stateful-across-calls doc comment). Done above
        // `startAnalysisLoop` so the loop can never observe stale filtered
        // state from before this point.
        filteredBuffer.clear()
        filter.reset()
        captureStalledGapOpen = false
        noSignalGapOpen = false
        // A fresh Start must not inherit a stale device-lost gap flag either --
        // otherwise a pinned device that disconnected in a PREVIOUS run would
        // silently suppress the gap the NEXT run's disconnect should open.
        deviceDisconnectGapOpen = false
        captureConnection = .connected
        // A fresh Start must not carry over a previous run's drop count --
        // otherwise a clean run would inherit and forever display a stale
        // number from before Stop. See the property's doc comment (I3).
        droppedArchiveWindowCount = 0
        // A fresh Start must treat its very first window as entirely new --
        // without resetting this, a stop() -> start() cycle would compute
        // the first post-restart window's "new" sample count against a
        // stale `totalWritten` high-water mark from the previous run.
        // `ringBuffer.clear()` above already resets `totalWritten` itself to
        // 0, so this and that reset must move together. See
        // `lastConsumedTotal`'s doc comment.
        lastConsumedTotal = nil
        recordedSampleCountForTesting = 0

        // Resolve the selected UID to a live device ID (nil → system default).
        do {
            try startCapture(targetDeviceUID: selectedInputDeviceUID)
        } catch let error as CaptureError {
            lastError = error
            return
        } catch {
            lastError = .engineStartFailed(error.localizedDescription)
            return
        }

        // Capture is up (isRunning == true) -- record who started this run.
        // Set here, not inside startCapture(): that method is also called by
        // resumeAfterReconnect(), and ownership must SURVIVE a reconnect, not
        // be reset by one.
        startedBySchedule = bySchedule

        if isRecordingEnabled {
            // `recordingRoot` defaults to nil, meaning `defaultRoot()` — the
            // real production location. Making this injectable (rather than
            // hardcoding `defaultRoot()` here) is what lets tests point
            // recording at a temporary directory instead of silently writing
            // to the user's real evidence database.
            let root = recordingRoot ?? RecordingPaths.defaultRoot()
            let paths = RecordingPaths(root: root)
            if let c = try? RecordingCoordinator(paths: paths, sampleRate: sampleRate,
                                                 resolveGapsOpenedBefore: launchTime) {
                coordinator = c
                let uid = recordingDeviceUID()   // the device that actually captures
                Task { await c.start(deviceUID: uid) }

                if isContinuousArchiveEnabled {
                    // Bounded, dropping consumer for archive audio -- see the
                    // `ArchiveChunk`/`archiveStreamBufferCount` doc comment above.
                    // `.bufferingNewest` drops the OLDEST buffered windows once
                    // full, which is what "a stalled disk loses the least-fresh
                    // audio, not the most-fresh" requires. Only stood up when
                    // the archive is actually enabled -- see that doc comment
                    // for what leaving this nil means for the rest of the file.
                    let (stream, continuation) = AsyncStream<ArchiveChunk>.makeStream(
                        bufferingPolicy: .bufferingNewest(Self.archiveStreamBufferCount))
                    archiveContinuation = continuation
                    archiveConsumerTask = Task {
                        for await chunk in stream {
                            await c.appendArchive(chunk.samples, wallClock: chunk.wallClock)
                        }
                    }
                }

                // Low-rate status polling, decoupled from analysis entirely
                // -- see the property doc comment. Fetches immediately (no
                // leading sleep) so the UI shows real status right away
                // rather than waiting out the first interval, then sleeps
                // between subsequent polls. Captures `c` directly (like
                // `archiveConsumerTask` above), not `self.coordinator`, so it
                // always polls the coordinator THIS start() created even if
                // a later start() replaces `self.coordinator` with a new one
                // before this task is torn down.
                //
                // Runs unconditionally -- NOT gated on `isContinuousArchiveEnabled`
                // -- for two reasons: recording health/eventsWritten must stay
                // visible with the archive off, and this is also what now
                // enforces the disk floor (`enforceStorageFloor`, called
                // first, every tick). That check used to live inside
                // `appendArchive`, so it silently stopped running whenever the
                // archive stream was never created; driving it from here
                // instead means the floor is enforced whether or not the
                // archive is running.
                recordingStatusTask = Task { [weak self] in
                    var pollsSinceHeartbeat = 0
                    while !Task.isCancelled {
                        await c.enforceStorageFloor(at: Date())
                        let status = await c.status()
                        guard let self, !Task.isCancelled else { return }
                        // `droppedArchiveWindowCount` is tracked session-side
                        // (see its doc comment, I3) -- merge it in rather than
                        // publishing the coordinator's status verbatim, which
                        // knows nothing about drops that never reached it.
                        //
                        // Republish only on a real change: an @Observable
                        // assignment invalidates observers even when the value is
                        // identical, and this polls at 1 Hz -- without the guard,
                        // the menu-bar dropdown (which reads recordingStatus)
                        // rebuilt once a second while open, disturbing selection.
                        let merged = status.withDroppedArchiveWindowCount(self.droppedArchiveWindowCount)
                        if self.recordingStatus != merged { self.recordingStatus = merged }

                        // Ride this same poll to heartbeat the monitoring span every
                        // `heartbeatPollCount` polls (~30s at 1 Hz) -- see that
                        // constant's doc comment. Deliberately NOT a separate
                        // task/timer: this task is already cancelled before
                        // `coordinator` is torn down (see `quiesceRunningSession`'s
                        // doc comment), so it can never heartbeat a finalized span.
                        pollsSinceHeartbeat += 1
                        if pollsSinceHeartbeat >= Self.heartbeatPollCount {
                            await c.heartbeatSpan(at: Date())
                            pollsSinceHeartbeat = 0
                        }

                        try? await Task.sleep(for: Self.recordingStatusPollInterval)
                    }
                }
            }
        }
    }

    /// Everything needed to write an event's clip when the event is still
    /// in progress at the moment its session ends (`stop()` /
    /// `failCaptureStalled(at:)` / `shutdown()`) rather than completing
    /// normally inside `processWindow`. Assembled synchronously by
    /// `prepareInProgressEventWrite` -- like `processWindow`'s own event
    /// branch -- so the clip is read out of `filteredBuffer` at the moment
    /// the event closes, not deferred into whatever later async Task
    /// actually reaches the coordinator (C2).
    private struct PendingEventWrite {
        let event: DetectedEvent
        let clip: [Float]
        let eventStartWallClock: Date
        let clipStartWallClock: Date
    }

    /// Mirrors `processWindow`'s TIMING comment on the event branch,
    /// generalized for an event that is force-finished (`EventDetector.finish`)
    /// rather than completed by `process(...)` releasing normally: there is
    /// no release wait to account for here, so instead of the
    /// duration+releaseTime arithmetic `processWindow` uses, this recovers
    /// the event's wall-clock start directly from a matched
    /// monotonic/wall-clock pair captured by the caller at the same
    /// instant (`now`/`wallNow`) -- the elapsed monotonic time since
    /// `event.startTime` translates onto `wallNow` the same way.
    private func prepareInProgressEventWrite(_ event: DetectedEvent, now: TimeInterval,
                                             wallNow: Date) -> PendingEventWrite {
        let elapsedSinceEventStart = now - event.startTime
        let preRollFrames = Int(sampleRate * Self.preRollSeconds)
        let eventFrames = Int(sampleRate * event.duration)
        // Whatever trailing time has elapsed since the event's last
        // above-release sample (`lastAboveRelease`, baked into
        // event.duration) and `now` -- e.g. the release window was still
        // counting down when the session ended. 0 for a maximumDuration-cap
        // completion, where `now` lands right at the event boundary already.
        let tailFrames = Int(sampleRate * max(elapsedSinceEventStart - event.duration, 0))
        let requestedFrames = preRollFrames + eventFrames + tailFrames
        let clip = filteredBuffer.latest(requestedFrames)

        let eventStart = wallNow.addingTimeInterval(-elapsedSinceEventStart)
        var clipStart = eventStart.addingTimeInterval(-Self.preRollSeconds)
        // Same short-buffer accounting as processWindow's event branch --
        // see its comment for why this must advance clipStart, not silently
        // claim audio that isn't in the returned clip.
        let shortfallFrames = requestedFrames - clip.count
        if shortfallFrames > 0 {
            clipStart = clipStart.addingTimeInterval(Double(shortfallFrames) / sampleRate)
        }
        return PendingEventWrite(event: event, clip: clip,
                                 eventStartWallClock: eventStart, clipStartWallClock: clipStart)
    }

    /// Synchronous teardown shared by `stop()` and `shutdown()`: halts
    /// capture and analysis, closes out any in-progress detector event
    /// (C2 -- appending it to `recentEvents` for the UI AND, if recording,
    /// assembling its clip synchronously via `prepareInProgressEventWrite`
    /// so nothing overwrites `filteredBuffer` before it's read), and tears
    /// down the archive stream and status polling. Does NOT touch
    /// `coordinator` itself -- each caller reads/nils it and finishes it in
    /// its own way (`stop()`: fire-and-forget; `shutdown()`: fully awaited)
    /// -- and does NOT set `lastError`, since `failCaptureStalled` has its
    /// own distinct teardown shape (see that method) and is not built on
    /// top of this helper.
    private func quiesceRunningSession(now: TimeInterval, wallNow: Date) -> PendingEventWrite? {
        analysisTask?.cancel()
        analysisTask = nil
        capture?.stop()
        capture = nil
        isRunning = false
        startedBySchedule = false

        var pendingEventWrite: PendingEventWrite?
        if let event = detector.finish(at: now) {
            appendEvent(event)
            if isRecordingEnabled, coordinator != nil {
                pendingEventWrite = prepareInProgressEventWrite(event, now: now, wallNow: wallNow)
            }
        }
        detectorState = detector.state

        // Finish the archive stream before dropping the coordinator: once
        // finished, the consumer's `for await` loop exits on its own after
        // draining whatever is still buffered, so no windows already handed
        // to the stream are lost by this stop.
        archiveContinuation?.finish()
        archiveContinuation = nil
        archiveConsumerTask = nil

        // Stop polling before dropping `coordinator`: the task holds its own
        // strong reference to the coordinator it polls (see the task's doc
        // comment), so it would otherwise keep running -- and keep
        // overwriting `recordingStatus` -- indefinitely after this session
        // has stopped. `recordingStatus` itself is cleared rather than left
        // at its last value so a stopped session never shows stale recording
        // health as if it were current.
        recordingStatusTask?.cancel()
        recordingStatusTask = nil
        recordingStatus = nil

        return pendingEventWrite
    }

    public func stop() {
        guard isRunning else { return }
        let pendingEventWrite = quiesceRunningSession(now: clock.now(), wallNow: Date())

        if let c = coordinator {
            coordinator = nil
            let band = self.band
            let threshold = detectorConfig.triggerDBFS
            // A single Task, awaiting the event write BEFORE `c.stop()`,
            // deliberately -- not two independent Tasks. `c.stop()` flips
            // the coordinator's `recording` flag false, and
            // `writeEventClip` silently no-ops (past a `lastError`/gap, but
            // still no clip) once that has happened. Two separately
            // scheduled Tasks would leave that ordering to chance; chaining
            // them in one Task guarantees the write reaches the actor
            // first (C2).
            Task {
                if let write = pendingEventWrite {
                    await c.writeEventClip(samples: write.clip, event: write.event,
                                           eventStartWallClock: write.eventStartWallClock,
                                           clipStartWallClock: write.clipStartWallClock,
                                           band: band, thresholdDBFS: threshold)
                }
                await c.stop()
            }
        }
    }

    /// Full, AWAITED teardown for process termination -- see
    /// `BandwatchApp`'s `NSApplicationDelegate` (C1). Unlike `stop()`,
    /// which deliberately returns immediately and lets the coordinator's
    /// teardown finish in a detached `Task` (so a Stop→Start UI cycle
    /// within one running process stays snappy), this method awaits every
    /// step -- the in-progress event's clip write, opening the `.shutdown`
    /// gap boundary, and the coordinator's own `shutdown()` -- because the
    /// caller is holding process termination open (`.terminateLater`)
    /// specifically so the process cannot exit mid-write. A FLAC file is
    /// unreadable until its writer is released (verified empirically), so
    /// if this returned before the archive segment's writer actually
    /// closed, quitting would still corrupt the in-progress segment exactly
    /// as before this fix.
    ///
    /// Opens (and, via the coordinator's own `stop()` inside `shutdown()`,
    /// immediately closes) a `.shutdown` gap: a deliberate, benign boundary
    /// marking "the app was quit here", distinct from every other gap
    /// reason, all of which represent a failure. Without it, the coverage
    /// log simply stops with no row explaining why -- indistinguishable
    /// from a crash.
    public func shutdown() async {
        guard isRunning else { return }
        let pendingEventWrite = quiesceRunningSession(now: clock.now(), wallNow: Date())

        guard let c = coordinator else { return }
        coordinator = nil
        let band = self.band
        let threshold = detectorConfig.triggerDBFS
        if let write = pendingEventWrite {
            await c.writeEventClip(samples: write.clip, event: write.event,
                                   eventStartWallClock: write.eventStartWallClock,
                                   clipStartWallClock: write.clipStartWallClock,
                                   band: band, thresholdDBFS: threshold)
        }
        await c.openGap(reason: .shutdown, at: Date())
        await c.shutdown()
    }

    /// Sets the detector trigger threshold from a user action and remembers it
    /// as the future default (persisted like the input-device selection).
    /// Setting `detectorConfig` directly — as internal code and tests do — is
    /// deliberately NOT persisted; only a genuine user threshold change is.
    public func setTriggerThreshold(_ dbfs: Double) {
        detectorConfig.triggerDBFS = dbfs
        defaults.set(dbfs, forKey: Self.thresholdDefaultsKey)
    }

    public func applySuggestedThreshold() {
        guard let suggested = suggestedThresholdDBFS else { return }
        setTriggerThreshold(suggested)
    }

    // MARK: Analysis

    private func startAnalysisLoop(generation: Int) {
        let interval = Double(hopSize) / sampleRate
        // This Task inherits @MainActor isolation from the enclosing class, so
        // the body already runs on the main actor — no MainActor.run needed.
        analysisTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.isRunning, self.analysisGeneration == generation else { return }
                self.processLoopIteration(now: self.clock.now())
                // processLoopIteration may have failed the session out
                // (capture stalled past threshold); stop looping immediately
                // rather than sleeping through one more dead interval.
                if !self.isRunning { return }
            }
        }
    }

    /// The per-tick body the analysis loop's Task runs after each
    /// `Task.sleep`. Factored out (rather than left inline in the Task
    /// closure) specifically so this decision — has the ring buffer actually
    /// advanced, and if not, for how long — can be driven directly from
    /// tests without depending on a live Task/timer or a running
    /// `AudioCaptureEngine`, neither of which is controllable deterministically
    /// in a test.
    func processLoopIteration(now: TimeInterval) {
        let totalWritten = ringBuffer.totalWritten
        guard totalWritten != lastObservedTotalWritten else {
            // No new samples arrived since the last check. Do NOT analyze,
            // append to levelHistory, or feed the baseline/detector —
            // `latest(fftSize)` would just return the same frozen window
            // again, and treating that as live data is exactly the
            // fabricated-evidence failure this guard exists to prevent.
            let stallStart = stallStartTime ?? now
            stallStartTime = stallStart
            if now - stallStart >= Self.captureStallThreshold {
                failCaptureStalled(at: now)
            }
            return
        }
        lastObservedTotalWritten = totalWritten
        stallStartTime = nil

        let samples = ringBuffer.latest(fftSize)
        guard samples.count == fftSize else { return }
        processWindow(samples, at: now)
    }

    /// Called once the ring buffer has gone `captureStallThreshold` seconds
    /// without advancing. Halts the session exactly as `stop()` does
    /// (closing out any in-progress event with the real data already
    /// accumulated) and publishes `.captureStalled` so the UI stops claiming
    /// to monitor a dead microphone.
    private func failCaptureStalled(at time: TimeInterval) {
        stallStartTime = nil
        let wallNow = Date()
        // Shares its synchronous teardown (and, per C2, in-progress-event
        // clip assembly) with stop() via quiesceRunningSession -- this
        // method's own distinct shape (lastError, the captureStalledGapOpen
        // guard, opening .captureStalled) resumes below.
        let pendingEventWrite = quiesceRunningSession(now: time, wallNow: wallNow)
        lastError = .captureStalled

        // Previously this only opened the gap and left `coordinator` in
        // place: a later start() would overwrite the reference, orphaning
        // this actor still holding `recording == true`, an open FLAC
        // segment, an open SQLite handle, and the gap just opened below —
        // permanently open, since nothing was ever left to close it, and
        // showing up as a stale open gap on the NEXT coordinator. Calling
        // `stop()` (mirroring `MonitoringSession.stop()`'s own coordinator
        // handling) closes the segment and this gap for real, and clearing
        // the reference here — not leaving it for the next start() to
        // silently replace — is what prevents two live coordinators from
        // ever existing against the same paths at once.
        if !captureStalledGapOpen, let c = coordinator {
            captureStalledGapOpen = true
            coordinator = nil
            let band = self.band
            let threshold = detectorConfig.triggerDBFS
            // Same single-Task ordering guarantee as stop() -- write the
            // in-progress event (C2) before c.stop() can flip `recording`
            // false underneath it.
            Task {
                if let write = pendingEventWrite {
                    await c.writeEventClip(samples: write.clip, event: write.event,
                                           eventStartWallClock: write.eventStartWallClock,
                                           clipStartWallClock: write.clipStartWallClock,
                                           band: band, thresholdDBFS: threshold)
                }
                await c.openGap(reason: .captureStalled, at: wallNow)
                await c.stop()
            }
        }
    }

    /// Drives the full pipeline from supplied samples, exercising the SAME
    /// code `processWindow` runs on the live loop -- including writing
    /// through `ringBuffer`, which is what `processWindow`'s new-sample-count
    /// computation now reads (see `lastConsumedTotal`'s doc comment).
    ///
    /// Previously this bypassed `ringBuffer` entirely and called
    /// `processWindow` directly, which was a real test-fidelity gap: the
    /// M1-M2 plan required this seam to drive the same path the live loop
    /// does, and the divergence is exactly what let both the M3 4x
    /// duplication bug and the M3.6 splice bug live behind a green suite.
    ///
    /// Writes only `hopSize` samples per call (the tail of `samples`) rather
    /// than the full `fftSize` window every test supplies: `samples` here
    /// represents the CURRENT full analysis window (what `processWindow`
    /// itself is given, unaltered, so every existing spectrum/level/detector
    /// assertion keeps seeing exactly the content it always has), but what
    /// a real capture thread would have newly delivered since the previous
    /// tick is only one hop's worth -- writing the whole window every call
    /// would make `ringBuffer.totalWritten` advance by `fftSize` per call
    /// instead of `hopSize`, reintroducing the very 4x duplication bug this
    /// file's M3.5 tests exist to catch. The very first call has no prior
    /// history to dedupe against regardless of what is written here --
    /// `processWindow`'s `lastConsumedTotal == nil` branch handles that by
    /// treating the whole first window as new, independent of this count.
    public func ingestForTesting(samples: [Float], at time: TimeInterval) {
        let newCount = min(hopSize, samples.count)
        let tail = Array(samples.suffix(newCount))
        tail.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { ringBuffer.write(base, count: tail.count) }
        }
        processWindow(samples, at: time)
    }

    /// Test-only: brings the session into the SAME "recording" state
    /// `start()` reaches once its `AudioCaptureEngine` starts successfully
    /// (`isRunning == true`, a live `RecordingCoordinator`, the archive
    /// stream wired up) WITHOUT requiring a real microphone or granted TCC
    /// permission -- both of which `start()` itself needs before any of
    /// that setup runs, making the disk-writing behavior exercised by C1/C2
    /// (`stop()`/`shutdown()` writing an in-progress event, closing a real
    /// segment) otherwise untestable in a sandboxed/CI environment with no
    /// microphone access. Analysis is driven directly via
    /// `ingestForTesting`/`processLoopIteration`, exactly as real tests
    /// already do -- this seam only replaces the capture-engine bring-up
    /// portion of `start()`, nothing about how audio is analyzed or
    /// recorded once running. `analysisTask` is deliberately left nil (no
    /// live timer loop): callers drive frames in directly.
    func startRecordingForTesting(root: URL, bySchedule: Bool = false) async {
        guard !isRunning else { return }
        ringBuffer.clear()
        lastObservedTotalWritten = 0
        stallStartTime = nil
        clock.reset()
        levelSmoother.reset()
        noSignalStartTime = nil
        inputHealth = .healthy
        lastPublishTime = nil
        filteredBuffer.clear()
        filter.reset()
        captureStalledGapOpen = false
        noSignalGapOpen = false
        // Mirrors start()'s own reset -- see that call site's comment.
        deviceDisconnectGapOpen = false
        captureConnection = .connected
        droppedArchiveWindowCount = 0
        lastConsumedTotal = nil
        recordedSampleCountForTesting = 0

        isRunning = true
        startedBySchedule = bySchedule
        analysisGeneration += 1
        isRecordingEnabled = true
        recordingRoot = root

        let paths = RecordingPaths(root: root)
        guard let c = try? RecordingCoordinator(paths: paths, sampleRate: sampleRate) else {
            isRunning = false
            startedBySchedule = false
            return
        }
        coordinator = c
        await c.start(deviceUID: "test")

        // Mirrors start()'s own gating -- see `isContinuousArchiveEnabled`'s
        // doc comment. Callers that need archive coverage under this seam
        // must set `isContinuousArchiveEnabled = true` before calling this.
        if isContinuousArchiveEnabled {
            let (stream, continuation) = AsyncStream<ArchiveChunk>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.archiveStreamBufferCount))
            archiveContinuation = continuation
            archiveConsumerTask = Task {
                for await chunk in stream {
                    await c.appendArchive(chunk.samples, wallClock: chunk.wallClock)
                }
            }
        }

        // Mirrors start()'s own polling task -- without this,
        // `recordingStatus` stays nil forever under this seam, which is
        // itself exactly the kind of gap I3 is about (a status nothing
        // reads). Also mirrors start()'s unconditional disk-floor
        // enforcement -- see that task's doc comment.
        recordingStatusTask = Task { [weak self] in
            var pollsSinceHeartbeat = 0
            while !Task.isCancelled {
                await c.enforceStorageFloor(at: Date())
                let status = await c.status()
                guard let self, !Task.isCancelled else { return }
                let merged = status.withDroppedArchiveWindowCount(self.droppedArchiveWindowCount)
                if self.recordingStatus != merged { self.recordingStatus = merged }

                // Mirrors start()'s own heartbeat wiring -- see that task's comment.
                pollsSinceHeartbeat += 1
                if pollsSinceHeartbeat >= Self.heartbeatPollCount {
                    await c.heartbeatSpan(at: Date())
                    pollsSinceHeartbeat = 0
                }

                try? await Task.sleep(for: Self.recordingStatusPollInterval)
            }
        }
    }

    /// Testing-only visibility into whether the analysis loop task is alive.
    /// `analysisTask` can hold at most one `Task` reference at a time (it's a
    /// single optional, not a collection), so "non-nil" here is equivalent to
    /// "exactly one live task" — this lets tests assert that invariant after
    /// a stop() -> start() cycle without exposing the task itself publicly.
    var hasAnalysisTaskForTesting: Bool { analysisTask != nil }

    /// Tracks how long the (smoothed) level has sat at or below
    /// `noSignalThresholdDBFS` and flips `inputHealth` once that has held for
    /// `noSignalDuration`. Recovery is automatic and immediate: the first
    /// window back above the threshold resets the timer and restores
    /// `.healthy`, with no restart required -- the mixer may simply have been
    /// switched back on.
    private func updateInputHealth(level: Double, at time: TimeInterval) {
        guard level < Self.noSignalThresholdDBFS else {
            noSignalStartTime = nil
            inputHealth = .healthy
            if noSignalGapOpen, let c = coordinator {
                noSignalGapOpen = false
                let wall = Date()
                // Close ONLY the .noSignal gap, not every open gap:
                // `.writeFailure` opens on any failed archive append (which
                // happen ~21.5/sec), so a `.writeFailure` gap being open at
                // the same moment `.noSignal` clears is unremarkable, not
                // exotic. `closeOpenGaps` would falsely record a genuinely
                // still-open `.writeFailure` gap as having ended here, in the
                // exact table whose purpose is proving coverage.
                // `closeOpenGaps` remains reserved for `stop()`, where the
                // whole session -- and every open condition along with it --
                // is genuinely ending.
                Task { await c.closeGap(reason: .noSignal, at: wall) }
            }
            return
        }
        let start = noSignalStartTime ?? time
        noSignalStartTime = start
        if time - start >= Self.noSignalDuration {
            inputHealth = .noSignal
            if !noSignalGapOpen, let c = coordinator {
                noSignalGapOpen = true
                let wall = Date()
                Task { await c.openGap(reason: .noSignal, at: wall) }
            }
        }
    }

    private func processWindow(_ samples: [Float], at time: TimeInterval) {
        let magnitudes = analyzer.analyze(samples)
        let rawLevel = meter.level(magnitudes: magnitudes, band: band)
        // IEC-style exponential time weighting: the raw per-frame level
        // thrashes 12-15 dB frame to frame on real microphone audio, which
        // fragments a single continuous noise into several detector events.
        // All downstream consumers use the smoothed level, not the raw one.
        let level = levelSmoother.smooth(rawLevel)

        updateInputHealth(level: level, at: time)

        // Filter and record only the audio that has not already been
        // recorded. `samples` is the full `fftSize` analysis window, which
        // overlaps 75% with the previous call's window (`hopSize` ==
        // `fftSize`/4) -- filtering and writing it in full every call, as
        // this used to do, filters (and writes) up to 4 overlapping copies
        // of the same audio (the M3 duplication bug).
        //
        // How much is genuinely new is derived from `ringBuffer.totalWritten`
        // -- a monotonic count of every sample the capture thread has ever
        // delivered -- rather than from elapsed `time` as this used to be.
        // The live loop wakes via `Task.sleep`, which jitters by a
        // millisecond or two per tick, so a `time`-derived count does not
        // exactly tile the arriving sample stream: every window boundary
        // either re-recorded a few already-recorded samples or skipped a
        // few that never got recorded (the M3.6 splice bug -- both are
        // clicks). `totalWritten` counts real delivered samples, so
        // consecutive reads of it tile the stream exactly, regardless of
        // loop jitter. See `lastConsumedTotal`'s doc comment.
        let totalWritten = ringBuffer.totalWritten
        let newSampleCount: Int
        if let last = lastConsumedTotal {
            let arrived = totalWritten - last
            // A delta larger than the ring buffer's own capacity means the
            // analysis loop fell far enough behind that some of that audio
            // was genuinely overwritten in the capture ring buffer before
            // ever being read -- it cannot be recovered, only clamped. The
            // `recordableCount`/`lostSampleCount` accounting just below
            // already opens a gap for whatever this clamp cuts off (it
            // already does the same for the far more common case of more
            // audio arriving than `samples` -- the fftSize analysis window
            // -- can represent), so the loss is recorded, not silent.
            newSampleCount = arrived > ringBuffer.capacity
                ? ringBuffer.capacity
                : max(arrived, 0)
        } else {
            // Nothing recorded yet this session -- the whole window is new,
            // and also seeds the pre-roll history.
            newSampleCount = samples.count
        }
        lastConsumedTotal = totalWritten

        // `samples` only ever holds `fftSize` samples of history. If more
        // real audio genuinely arrived than that since the last pass (a
        // scheduling stall on the main actor long enough to exceed the
        // analysis window, though short of the full capture-stall
        // threshold), the excess beyond what the window can supply is
        // truly unrecoverable here -- it must be surfaced as a gap, not
        // silently dropped or double-recorded.
        let recordableCount = min(newSampleCount, samples.count)
        let lostSampleCount = newSampleCount - recordableCount
        let newSamples = Array(samples.suffix(recordableCount))

        // This is the ONLY audio that ever reaches disk. Must run -- and
        // land in `filteredBuffer` -- before `detector.process` below,
        // since an event emitted from THIS window needs the buffer to
        // already include it when the clip is assembled.
        let filtered = filter.process(newSamples)
        lastFilteredSamplesForTesting = filtered
        recordedSampleCountForTesting += filtered.count
        filtered.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { filteredBuffer.write(base, count: filtered.count) }
        }
        if lostSampleCount > 0, isRecordingEnabled, let coordinator {
            // Mirrors the dropped-archive-window handling just below: a
            // coverage gap must never be silent (I3). `.writeFailure` is
            // the closest existing reason -- audio that genuinely arrived
            // but could never be recovered for recording, distinct from a
            // disk write that was attempted and failed, but there is no
            // dedicated reason for "arrived audio the analysis window could
            // not represent."
            let wall = Date()
            Task { await coordinator.openGap(reason: .writeFailure, at: wall) }
        }
        if isRecordingEnabled, let archiveContinuation, !filtered.isEmpty {
            let wall = Date()
            // Synchronous, non-blocking: `processWindow` must never `await`.
            // `.bufferingNewest` means a stalled disk drops the OLDEST
            // buffered windows once the bounded buffer fills, rather than
            // accumulating `Task`s (and their retained `[Float]`s) without
            // limit -- but a drop is still lost audio, so it must not be
            // silent.
            switch archiveContinuation.yield(ArchiveChunk(samples: filtered, wallClock: wall)) {
            case .dropped:
                droppedArchiveWindowCount += 1
                if let coordinator {
                    // Fire-and-forget, like the other edge-condition gap
                    // opens in this file (noSignalGapOpen/captureStalledGapOpen)
                    // -- but unlike those, this is not itself edge-triggered:
                    // it fires on every drop. That is safe because
                    // `noteArchiveWindowDropped` funnels into `openGap`,
                    // which dedupes repeat opens for the same reason to the
                    // one already-open row (see its doc comment) -- so a
                    // sustained stall spawns many small Tasks (no retained
                    // audio, unlike the per-window archive Task this
                    // replaced pre-M3) but only the FIRST one actually
                    // reaches SQLite. The discontinuity this creates in the
                    // archive file must not be silent (I3).
                    Task { await coordinator.noteArchiveWindowDropped(at: wall) }
                }
            case .enqueued, .terminated:
                break
            @unknown default:
                break
            }
        }

        // Working copies are updated unconditionally, every single frame, at
        // the full analysis rate -- these are `@ObservationIgnored`, so this
        // costs nothing in SwiftUI invalidation. `levelHistory`'s cap is
        // enforced here too so the working copy never grows unbounded even
        // while display publishing is throttled.
        workingFrame = AnalysisFrame(magnitudes: magnitudes, bandLevelDBFS: level, timestamp: time)
        workingLevelHistory.append(level)
        if workingLevelHistory.count > Self.levelHistoryCapacity {
            workingLevelHistory.removeFirst(workingLevelHistory.count - Self.levelHistoryCapacity)
        }

        // Baseline and detector see every frame, unthrottled -- detection
        // accuracy depends on it. Nothing above this point is gated on the
        // display cadence.
        baseline.add(level: level)
        // Published immediately rather than throttled: unlike latestFrame's
        // spectrum array and levelHistory's up-to-1800-element array, this is
        // a single Double? -- observing it costs nothing, and publishing it
        // immediately (like the state-transition properties below) avoids a
        // one-frame lag that would otherwise leave a suggestion invisible for
        // up to one displayInterval right at the moment it first matures.
        suggestedThresholdDBFS = baseline.suggestedThresholdDBFS

        if let event = detector.process(level: level, at: time) {
            appendEvent(event)
            if isRecordingEnabled, let coordinator {
                // TIMING — get this right or every clip is shifted.
                //
                // The detector emits an event only AFTER the release window
                // elapses, so "now" is roughly (event end + releaseTime), not
                // the event end. Taking preRoll + duration from the buffer
                // would therefore land late: you would get only
                // (preRoll - releaseTime) of lead-in and a tail of silence.
                //
                // Capture preRoll + duration + releaseTime so the clip
                // contains the full lead-in AND the noise audibly stopping,
                // which is better evidence than a clip that cuts off at the
                // last loud sample.
                let releaseSeconds = detectorConfig.releaseTime
                let preRollFrames = Int(sampleRate * Self.preRollSeconds)
                let eventFrames = Int(sampleRate * event.duration)
                let releaseFrames = Int(sampleRate * releaseSeconds)
                let requestedFrames = preRollFrames + eventFrames + releaseFrames
                let clip = filteredBuffer.latest(requestedFrames)

                // Two DISTINCT wall-clock values, deliberately not collapsed
                // into one (see RecordingCoordinator.writeEventClip's doc
                // comment for why that collapse falsifies every event row):
                //
                // `eventStart` — when the NOISE itself began. This is what
                // goes into the database row. The detector emits an event
                // only AFTER the release window elapses, so "now" (`Date()`)
                // is roughly (event end + releaseTime), not the event start —
                // walking back by (duration + releaseTime) recovers it.
                //
                // `clipStart` — when the recorded AUDIO begins, i.e.
                // `eventStart` minus the pre-roll. This is what names the
                // clip file: the filename must match the first sample
                // actually in it.
                let eventStart = Date().addingTimeInterval(-(event.duration + releaseSeconds))
                var clipStart = eventStart.addingTimeInterval(-Self.preRollSeconds)

                // `RingBuffer.latest` short-returns silently if fewer than
                // `requestedFrames` were actually available (e.g. right after
                // a Start, before preRoll seconds of history has
                // accumulated). When that happens, the returned audio's
                // OLDEST sample is later than `clipStart` by the shortfall —
                // `latest` always returns the newest samples, so a shortfall
                // is missing history, not missing tail. Advance `clipStart`
                // forward by that shortfall so the claimed clip start still
                // matches the audio actually present, rather than claiming
                // audio exists before the first sample in the file.
                let shortfallFrames = requestedFrames - clip.count
                if shortfallFrames > 0 {
                    clipStart = clipStart.addingTimeInterval(Double(shortfallFrames) / sampleRate)
                }

                let band = self.band
                let threshold = detectorConfig.triggerDBFS
                // Event clips stay on their own Task, separate from the
                // bounded archive stream: they are rare and must never be
                // dropped, unlike the continuous archive audio above.
                Task {
                    await coordinator.writeEventClip(samples: clip, event: event,
                                                     eventStartWallClock: eventStart,
                                                     clipStartWallClock: clipStart,
                                                     band: band, thresholdDBFS: threshold)
                }
            }
        }
        // State transitions publish immediately, never on the display
        // cadence: a user must see `.recording` start/stop promptly, and
        // this changes rarely enough that publishing it every frame costs
        // nothing.
        detectorState = detector.state

        publishDisplayStateIfDue(at: time)
    }

    /// Copies the working (unthrottled) display state into the observed
    /// properties that drive SwiftUI, but only once `displayInterval` has
    /// elapsed since the last publish. `time` is the caller-supplied
    /// analysis timestamp -- this never reads the clock directly.
    private func publishDisplayStateIfDue(at time: TimeInterval) {
        let elapsedSinceLastPublish = lastPublishTime.map { time - $0 } ?? .infinity
        guard elapsedSinceLastPublish >= Self.displayInterval else { return }
        lastPublishTime = time
        latestFrame = workingFrame
        levelHistory = workingLevelHistory
    }

    private func appendEvent(_ event: DetectedEvent) {
        recentEvents.append(event)
        if recentEvents.count > Self.recentEventsCapacity {
            recentEvents.removeFirst(recentEvents.count - Self.recentEventsCapacity)
        }
    }
}

extension MonitoringSession: SchedulableSession {
    public var isMonitoring: Bool { isRunning }
    public var isScheduleOwned: Bool { startedBySchedule }
    // `start` is async; the scheduler's edge logic is synchronous, so spawn a
    // Task. Ordering is fine — the scheduler only starts when nothing is running.
    public func startScheduled() { Task { await start(bySchedule: true) } }
    public func stopScheduled() { stop() }
}
