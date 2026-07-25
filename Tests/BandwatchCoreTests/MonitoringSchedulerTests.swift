import Testing
import Foundation
@testable import BandwatchCore

@MainActor private final class FakeSession: SchedulableSession {
    var isMonitoring = false
    var isScheduleOwned = false
    var startCount = 0, stopCount = 0
    func startScheduled() { startCount += 1; isMonitoring = true; isScheduleOwned = true }
    func stopScheduled() { stopCount += 1; isMonitoring = false; isScheduleOwned = false }
}
private func at(_ h: Int, _ m: Int) -> Date {   // today at h:m local
    Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())!
}
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "bw-\(UUID().uuidString)")! }

@MainActor @Test func testRisingEdgeStartsFallingEdgeStops() {
    let f = FakeSession()
    let d = freshDefaults()
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d)
    sch.evaluate(now: at(5, 59)); #expect(f.startCount == 0)   // before window
    sch.evaluate(now: at(6, 0));  #expect(f.startCount == 1)   // rising edge -> start
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 1)   // still in window, no re-start
    sch.evaluate(now: at(18, 0)); #expect(f.stopCount == 1)    // falling edge -> stop
}

@MainActor @Test func testManualStopMidWindowIsNotRestarted() {
    let f = FakeSession()
    let d = freshDefaults()
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d)
    sch.evaluate(now: at(6, 0)); #expect(f.startCount == 1)
    f.isMonitoring = false; f.isScheduleOwned = false          // user stopped it
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 1)   // NOT restarted (no edge)
}

@MainActor @Test func testFallingEdgeLeavesManualSessionRunning() {
    let f = FakeSession()
    let d = freshDefaults()
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d)
    // A manual session is already running when the window opens.
    f.isMonitoring = true; f.isScheduleOwned = false
    sch.evaluate(now: at(6, 0)); #expect(f.startCount == 0)    // does not adopt
    sch.evaluate(now: at(18, 0)); #expect(f.stopCount == 0)    // does not stop a manual session
}

@MainActor @Test func testCatchUpStartsWhenEnabledMidWindow() {
    let f = FakeSession()
    let d = freshDefaults()
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d)
    sch.evaluate(now: at(10, 0)); #expect(f.startCount == 1)   // first eval already in window -> start
}

@MainActor @Test func testDisabledScheduleDoesNothing() {
    let f = FakeSession()
    let d = freshDefaults()
    MonitoringSchedule(isEnabled: false, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d)
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 0)
}
