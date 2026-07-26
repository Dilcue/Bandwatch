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
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastInWindow: Bool?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    // Safe unsafe: only ever read/written on MainActor while `self` is alive; by the time
    // `deinit` runs (which also touches it off-actor-checked), no other reference to this
    // instance exists, so there is no concurrent MainActor access to race with.
    @ObservationIgnored nonisolated(unsafe) private var awakeToken: (any NSObjectProtocol)?

    private static let tickInterval: Duration = .seconds(30)

    public init(session: SchedulableSession, defaults: UserDefaults = .bandwatch,
                calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.schedule = MonitoringSchedule.load(from: defaults)
        if schedule.isEnabled { activate() }
    }

    /// The tested seam: given the wall-clock instant, act on any window edge.
    func evaluate(now: Date) {
        let minute = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        let inWindow = schedule.isEnabled && schedule.isWithin(minuteOfDay: minute)
        if inWindow, lastInWindow != true {
            if !session.isMonitoring { session.startScheduled() }     // rising: start, never adopt
        } else if !inWindow, lastInWindow == true {
            if session.isMonitoring, session.isScheduleOwned {
                session.stopScheduled()                               // falling: stop only what we own
            }
        }
        lastInWindow = inWindow
    }

    private func activate() {
        // Enabling the schedule (or launching with it already enabled) is the
        // moment to secure mic access — the user is here to answer the prompt,
        // rather than the scheduled window hitting it unattended at, say, 6 AM.
        session.requestMicrophonePermissionForSchedule()
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
