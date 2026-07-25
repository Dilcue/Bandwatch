import Foundation

/// A single recurring daily monitoring window, stored as minutes-of-day (local)
/// so it is a wall-clock time independent of any date and stable across DST.
public struct MonitoringSchedule: Equatable, Sendable {
    public var isEnabled: Bool
    public var startMinuteOfDay: Int   // 0..<1440
    public var endMinuteOfDay: Int     // 0..<1440

    public static let defaultStartMinute = 6 * 60    // 06:00
    public static let defaultEndMinute = 18 * 60     // 18:00

    public init(isEnabled: Bool = false,
                startMinuteOfDay: Int = MonitoringSchedule.defaultStartMinute,
                endMinuteOfDay: Int = MonitoringSchedule.defaultEndMinute) {
        self.isEnabled = isEnabled
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }

    /// Whether `minuteOfDay` (0..<1440) is inside the window. Inclusive of start,
    /// exclusive of end. `start == end` is a zero-length window: never active.
    public func isWithin(minuteOfDay m: Int) -> Bool {
        if startMinuteOfDay == endMinuteOfDay { return false }
        if startMinuteOfDay < endMinuteOfDay {
            return m >= startMinuteOfDay && m < endMinuteOfDay
        }
        return m >= startMinuteOfDay || m < endMinuteOfDay   // overnight wrap
    }

    private enum Key {
        static let enabled = "bandwatch.schedule.enabled"
        static let start = "bandwatch.schedule.startMinute"
        static let end = "bandwatch.schedule.endMinute"
    }

    public static func load(from defaults: UserDefaults) -> MonitoringSchedule {
        // `object(forKey:)` distinguishes "never set" (→ defaults) from a stored 0.
        let start = defaults.object(forKey: Key.start) as? Int ?? defaultStartMinute
        let end = defaults.object(forKey: Key.end) as? Int ?? defaultEndMinute
        return MonitoringSchedule(isEnabled: defaults.bool(forKey: Key.enabled),
                                  startMinuteOfDay: start, endMinuteOfDay: end)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(startMinuteOfDay, forKey: Key.start)
        defaults.set(endMinuteOfDay, forKey: Key.end)
    }
}
