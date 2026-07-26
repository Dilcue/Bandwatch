import Foundation
import UserNotifications

/// Seam over local macOS notifications, so scheduled-monitoring code (Task 4/5)
/// can surface unattended failures without ever talking to
/// `UNUserNotificationCenter` directly. Tests inject a fake; the app wires up
/// `SystemUserNotifier`.
@MainActor
public protocol UserNotifying: AnyObject {
    /// Ask the OS for notification permission. A no-op if already
    /// determined; safe to call repeatedly (e.g. on every app launch).
    func requestAuthorization() async

    /// Deliver a notification immediately. `id` identifies the *condition*
    /// being reported, not the individual post -- callers that post the same
    /// `id` again (e.g. the same failure recurring on a later scheduled run)
    /// should not see a second, redundant notification pile up. Conformers
    /// are responsible for that dedupe.
    func post(title: String, body: String, id: String)
}

/// Why a scheduled monitoring start could not proceed unattended. This is
/// distinct from `MonitoringSession.StartBlockedReason` -- that type drives
/// in-app UI state; this one exists to pick notification copy for the case
/// where nobody is watching the app to see that UI.
public enum ScheduledStartBlockReason: Equatable, Sendable {
    /// No input device has ever been selected.
    case noDeviceSelected
    /// A device was selected, but it is not currently present/reachable.
    case deviceUnavailable(name: String)

    public var notificationTitle: String {
        "Bandwatch: Scheduled Monitoring Skipped"
    }

    public var notificationBody: String {
        switch self {
        case .noDeviceSelected:
            return "No input device is selected, so scheduled monitoring did not start. Open Bandwatch and choose an input device."
        case .deviceUnavailable(let name):
            return "The selected input device \u{201c}\(name)\u{201d} is unavailable, so scheduled monitoring did not start. Reconnect it or choose another device in Bandwatch."
        }
    }

    /// Stable per-case identifier used to dedupe repeat notifications for the
    /// same underlying condition. Deliberately excludes `deviceUnavailable`'s
    /// associated `name` -- only one device is ever selected at a time, and
    /// keying on the case alone means a run of consecutive missed nights
    /// collapses to one notification instead of paging the same failure
    /// repeatedly.
    public var notificationID: String {
        switch self {
        case .noDeviceSelected:
            return "scheduled-start-blocked.no-device-selected"
        case .deviceUnavailable:
            return "scheduled-start-blocked.device-unavailable"
        }
    }
}

public extension UserNotifying {
    /// Convenience for the scheduler: map a block reason straight to its
    /// notification copy and stable id.
    func post(blocked reason: ScheduledStartBlockReason) {
        post(title: reason.notificationTitle, body: reason.notificationBody, id: reason.notificationID)
    }
}

/// Real `UNUserNotificationCenter`-backed notifier. Authorization is checked
/// (never requested) at post time; `requestAuthorization()` is the only place
/// that prompts, so callers control when the OS permission dialog can appear.
@MainActor
public final class SystemUserNotifier: UserNotifying {
    private var postedIDs: Set<String> = []

    public init() {}

    public func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func post(title: String, body: String, id: String) {
        // Dedupe up front: a condition that keeps recurring (e.g. no device
        // selected on every subsequent scheduled run) must only ever notify
        // once per session, regardless of how the authorization check below
        // resolves.
        guard postedIDs.insert(id).inserted else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            // `trigger: nil` delivers immediately.
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
