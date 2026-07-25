import Foundation

/// What `MonitoringScheduler` needs from the thing it drives. A protocol seam so
/// the scheduler's edge logic can be unit-tested against a fake without a real
/// `MonitoringSession` (mirrors `InputDeviceEnumerating`).
@MainActor public protocol SchedulableSession: AnyObject {
    var isMonitoring: Bool { get }
    var isScheduleOwned: Bool { get }
    func startScheduled()
    func stopScheduled()
}
