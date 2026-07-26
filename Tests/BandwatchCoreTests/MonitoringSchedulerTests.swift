import Testing
import Foundation
@testable import BandwatchCore

@MainActor private final class FakeSession: SchedulableSession {
    var isMonitoring = false
    var isScheduleOwned = false
    var startCount = 0, stopCount = 0
    var permissionRequestCount = 0
    func startScheduled() { startCount += 1; isMonitoring = true; isScheduleOwned = true }
    func stopScheduled() { stopCount += 1; isMonitoring = false; isScheduleOwned = false }
    func requestMicrophonePermissionForSchedule() { permissionRequestCount += 1 }
}
private func at(_ h: Int, _ m: Int) -> Date {   // today at h:m local
    Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())!
}
/// Creates a throwaway `UserDefaults` suite and removes it when the calling
/// test scope ends, so ad-hoc suites don't accumulate in the test host's
/// defaults domain across runs.
private func freshDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    let name = "bw-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@MainActor @Test func testRisingEdgeStartsFallingEdgeStops() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    sch.evaluate(now: at(5, 59)); #expect(f.startCount == 0)   // before window
    sch.evaluate(now: at(6, 0));  #expect(f.startCount == 1)   // rising edge -> start
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 1)   // still in window, no re-start
    sch.evaluate(now: at(18, 0)); #expect(f.stopCount == 1)    // falling edge -> stop
}

@MainActor @Test func testManualStopMidWindowIsNotRestarted() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    sch.evaluate(now: at(6, 0)); #expect(f.startCount == 1)
    f.isMonitoring = false; f.isScheduleOwned = false          // user stopped it
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 1)   // NOT restarted (no edge)
}

@MainActor @Test func testFallingEdgeLeavesManualSessionRunning() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    // A manual session is already running when the window opens.
    f.isMonitoring = true; f.isScheduleOwned = false
    sch.evaluate(now: at(6, 0)); #expect(f.startCount == 0)    // does not adopt
    sch.evaluate(now: at(18, 0)); #expect(f.stopCount == 0)    // does not stop a manual session
}

@MainActor @Test func testCatchUpStartsImmediatelyWhenEnabledMidWindow() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(10, 0) })
    _ = sch                       // constructed mid-window
    #expect(f.startCount == 1)    // immediate catch-up on init/activate, no evaluate() call
}

@MainActor @Test func testDisabledScheduleDoesNothing() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: false, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    sch.evaluate(now: at(12, 0)); #expect(f.startCount == 0)
}

@MainActor @Test func testEnablingScheduleRequestsMicrophonePermission() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    // Start disabled: nothing requested at init.
    MonitoringSchedule(isEnabled: false, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    #expect(f.permissionRequestCount == 0)
    // Checking the box activates the schedule and secures mic access up front.
    sch.schedule.isEnabled = true
    #expect(f.permissionRequestCount == 1)
}

@MainActor @Test func testLaunchWithScheduleEnabledRequestsMicrophonePermission() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(0, 0) })
    _ = sch                            // activate() at init requests too
    #expect(f.permissionRequestCount == 1)
}

/// Regression test: editing the schedule's times so the window no longer
/// covers "now" must stop a scheduler-owned session that's currently
/// running. Before the fix, the "times changed" didSet branch reset
/// `lastInWindow` to nil, which made the falling-edge check in
/// `evaluate(now:)` (which requires `lastInWindow == true`) impossible to
/// satisfy on the very next evaluation -- so a narrowed window would never
/// stop an in-progress owned session until some later edge.
@MainActor @Test func testTimesChangedEditStopsOwnedRunningSession() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(10, 0) })
    #expect(f.startCount == 1)       // catch-up start, scheduler-owned
    #expect(f.isScheduleOwned)

    sch.schedule.endMinuteOfDay = 9 * 60   // narrow window to 6-9: 10:00 is now outside
    #expect(f.stopCount == 1)              // owned session must be stopped by the edit
}

/// Same kind of edit, but the running session was started manually (not
/// scheduler-owned): the scheduler must never stop a manual session, even
/// when a times-changed edit moves the window off "now".
@MainActor @Test func testTimesChangedEditNeverStopsManualSession() {
    let f = FakeSession()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, now: { at(10, 0) })
    #expect(f.startCount == 1)              // catch-up adopts nothing; starts its own
    // Replace the scheduler-started session with a manually-started one, as if
    // the user stopped the scheduled run and started monitoring by hand.
    f.stopCount = 0
    f.isMonitoring = true; f.isScheduleOwned = false

    sch.schedule.endMinuteOfDay = 9 * 60   // narrow window to 6-9: 10:00 is now outside
    #expect(f.stopCount == 0)              // manual session must never be stopped
    #expect(f.isMonitoring)                // still running
}
