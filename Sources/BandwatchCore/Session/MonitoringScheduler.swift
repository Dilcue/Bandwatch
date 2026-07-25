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
}

@MainActor @Observable public final class MonitoringScheduler {
    public var schedule: MonitoringSchedule {
        didSet {
            guard schedule != oldValue else { return }
            schedule.save(to: defaults)
            if schedule.isEnabled != oldValue.isEnabled {
                schedule.isEnabled ? activate() : deactivate()
            } else if schedule.isEnabled {
                lastInWindow = nil            // times changed: re-evaluate cleanly
                evaluate(now: Date())
            }
        }
    }

    @ObservationIgnored private let session: SchedulableSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var lastInWindow: Bool?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var awakeToken: (any NSObjectProtocol)?

    private static let tickInterval: Duration = .seconds(30)

    public init(session: SchedulableSession, defaults: UserDefaults = .bandwatch,
                calendar: Calendar = .current) {
        self.session = session
        self.defaults = defaults
        self.calendar = calendar
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
        acquireKeepAwake()
        lastInWindow = nil
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.evaluate(now: Date())
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
