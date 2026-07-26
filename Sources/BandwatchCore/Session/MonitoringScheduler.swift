import Foundation
import Observation

/// What `MonitoringScheduler` needs from the thing it drives. A protocol seam so
/// the scheduler's edge logic can be unit-tested against a fake without a real
/// `MonitoringSession` (mirrors `InputDeviceEnumerating`).
@MainActor public protocol SchedulableSession: AnyObject {
    var isMonitoring: Bool { get }
    var isScheduleOwned: Bool { get }
    func startScheduled()
    func stopScheduled()
    /// Prompt for microphone access now, while the user is present, so an
    /// unattended scheduled start later doesn't hit an undetermined-permission
    /// prompt (or silently fail). No-op if access is already decided.
    func requestMicrophonePermissionForSchedule()

    /// True when there is a currently usable (chosen AND present) input
    /// device selected. Lets the armed-idle watch below tell "armed, but the
    /// device just vanished" apart from "armed and fine" without the
    /// scheduler needing to know anything about how devices are chosen.
    func hasUsableSelectedDevice() -> Bool

    /// Best-known display name of the currently pinned/selected device, or
    /// nil when nothing has EVER been chosen. Unaffected by whether that
    /// device is currently present -- used only to name it in the armed-idle
    /// notification copy below.
    func selectedDeviceDisplayName() -> String?

    /// Whether the armed-idle watch currently considers the selected device
    /// missing (schedule armed, nothing running, device unavailable). Set by
    /// the scheduler; observed by the UI to show a banner.
    var armedDeviceMissing: Bool { get set }
}

@MainActor @Observable public final class MonitoringScheduler {
    public var schedule: MonitoringSchedule {
        didSet {
            guard schedule != oldValue else { return }
            schedule.save(to: defaults)
            if schedule.isEnabled != oldValue.isEnabled {
                schedule.isEnabled ? activate() : deactivate()
            } else if schedule.isEnabled {
                // Times changed: seed from current owned-running state (not nil) so that
                // if the new window excludes "now" while we own a running session, the
                // falling-edge branch in evaluate(now:) can still fire and stop it.
                lastInWindow = session.isMonitoring && session.isScheduleOwned
                evaluate(now: now())
            }
        }
    }

    @ObservationIgnored private let session: SchedulableSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let notifier: UserNotifying?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastInWindow: Bool?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Dedupe for the armed-idle "device missing" notification: true once it
    /// has been posted for the CURRENT missing episode, reset back to false
    /// as soon as the device is usable again (or the schedule is no longer
    /// armed-idle) so a later episode alerts again. The real `UserNotifying`
    /// conformer (`SystemUserNotifier`) additionally dedupes by `id` for the
    /// life of the process -- this flag only governs repeat posts WITHIN one
    /// episode, e.g. across successive ticks.
    @ObservationIgnored private var armedIdleDeviceMissingPosted = false
    // Safe unsafe: only ever read/written on MainActor while `self` is alive; by the time
    // `deinit` runs (which also touches it off-actor-checked), no other reference to this
    // instance exists, so there is no concurrent MainActor access to race with.
    @ObservationIgnored nonisolated(unsafe) private var awakeToken: (any NSObjectProtocol)?

    private static let tickInterval: Duration = .seconds(30)

    public init(session: SchedulableSession, defaults: UserDefaults = .bandwatch,
                calendar: Calendar = .current, notifier: UserNotifying? = nil,
                now: @escaping () -> Date = Date.init) {
        self.session = session
        self.defaults = defaults
        self.calendar = calendar
        self.notifier = notifier
        self.now = now
        self.schedule = MonitoringSchedule.load(from: defaults)
        if schedule.isEnabled { activate() }
    }

    /// The tested seam: given the wall-clock instant, act on any window edge.
    func evaluate(now: Date) {
        let minute = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        let inWindow = schedule.isEnabled && schedule.isWithin(minuteOfDay: minute)
        var justAttemptedStart = false
        if inWindow, lastInWindow != true {
            if !session.isMonitoring {
                session.startScheduled()                               // rising: start, never adopt
                justAttemptedStart = true
            }
        } else if !inWindow, lastInWindow == true {
            if session.isMonitoring, session.isScheduleOwned {
                session.stopScheduled()                               // falling: stop only what we own
            }
        }
        lastInWindow = inWindow
        // Self-healing backstop for the armed-idle watch: even if no device
        // topology change ever calls `deviceAvailabilityChanged()` (or the
        // app forgot to wire it up), the periodic 30s tick still catches an
        // armed-but-idle schedule sitting on a missing device.
        //
        // Skipped for one tick right after a rising-edge start attempt:
        // `startScheduled()` is fire-and-forget (spawns a Task), so
        // `session.isMonitoring` has not flipped true yet even on success,
        // and on the blocked-device path `MonitoringSession.start(bySchedule:)`
        // posts its OWN blocked-start notification moments later -- without
        // this guard, that first tick would see "armed, not yet monitoring,
        // device missing" and fire a second, redundant notification for the
        // exact same instant. The very next tick (30s later, or the next
        // `deviceAvailabilityChanged()`) still catches a genuinely still-blocked
        // device, since `lastInWindow` is now `true` and won't re-attempt a start.
        if !justAttemptedStart {
            updateArmedIdleDeviceWatch()
        }
    }

    /// Call when the input device topology may have changed (wired to
    /// `MonitoringSession.onDeviceAvailabilityChange` by the app) so the
    /// armed-idle watch below reacts immediately to a device
    /// appearing/disappearing, rather than waiting out the periodic tick.
    public func deviceAvailabilityChanged() {
        updateArmedIdleDeviceWatch()
    }

    /// While the schedule is armed (enabled) but nothing is currently
    /// running, a selected device going missing is a silent failure nobody
    /// would notice until the next window comes and goes empty-handed. This
    /// surfaces it right away: a banner flag on the session (`armedDeviceMissing`)
    /// plus one deduped notification per missing episode. Deliberately
    /// distinct from the blocked-start path (`MonitoringSession.start(bySchedule:)`),
    /// which only fires AT a scheduled start attempt -- this fires the moment
    /// the device disappears, whether or not a window is imminent.
    private func updateArmedIdleDeviceWatch() {
        guard schedule.isEnabled, !session.isMonitoring else {
            session.armedDeviceMissing = false
            armedIdleDeviceMissingPosted = false
            return
        }
        guard !session.hasUsableSelectedDevice(), let name = session.selectedDeviceDisplayName() else {
            // Either a usable device is selected, or nothing has ever been
            // chosen at all -- the latter has nothing to report "missing"
            // (the blocked-start path covers it instead).
            session.armedDeviceMissing = false
            armedIdleDeviceMissingPosted = false
            return
        }
        session.armedDeviceMissing = true
        guard !armedIdleDeviceMissingPosted else { return }
        armedIdleDeviceMissingPosted = true
        notifier?.post(title: Self.armedIdleDeviceMissingTitle,
                        body: "Scheduled input '\(name)' is unavailable — reconnect before the next window.",
                        id: Self.armedIdleDeviceMissingID)
    }

    private static let armedIdleDeviceMissingTitle = "Bandwatch: Input Device Unavailable"
    private static let armedIdleDeviceMissingID = "armed-idle.device-missing"

    private func activate() {
        // Enabling the schedule (or launching with it already enabled) is the
        // moment to secure mic access — the user is here to answer the prompt,
        // rather than the scheduled window hitting it unattended at, say, 6 AM.
        session.requestMicrophonePermissionForSchedule()
        // Same reasoning for notification permission: ask while the user is
        // present so an unattended blocked-start or armed-idle alert later
        // doesn't silently vanish behind an undetermined/never-asked prompt.
        // `requestAuthorization()` is async and safe to call repeatedly (a
        // no-op once already determined), so fire-and-forget is fine here.
        Task { [notifier] in await notifier?.requestAuthorization() }
        acquireKeepAwake()
        // Seed from current owned-running state (not nil) so that if the newly-enabled
        // window excludes "now" while we own a running session, the falling-edge branch
        // in evaluate(now:) can still fire and stop it.
        lastInWindow = session.isMonitoring && session.isScheduleOwned
        evaluate(now: now())          // catch up immediately: enabling/launching mid-window starts right away
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.evaluate(now: self.now())
            }
        }
    }

    private func deactivate() {
        tickTask?.cancel(); tickTask = nil
        lastInWindow = nil
        releaseKeepAwake()
        // A disarmed schedule can no longer be "armed-idle" -- clear any
        // banner/dedupe state left over from before disabling.
        session.armedDeviceMissing = false
        armedIdleDeviceMissingPosted = false
        // Deliberately does NOT stop an in-progress session — see spec.
    }

    private func acquireKeepAwake() {
        guard awakeToken == nil else { return }
        awakeToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Bandwatch scheduled monitoring")
    }

    private func releaseKeepAwake() {
        if let awakeToken { ProcessInfo.processInfo.endActivity(awakeToken) }
        awakeToken = nil
    }

    deinit { if let awakeToken { ProcessInfo.processInfo.endActivity(awakeToken) } }
}
