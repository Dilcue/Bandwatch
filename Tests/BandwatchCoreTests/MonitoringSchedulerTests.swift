import Testing
import Foundation
@testable import BandwatchCore

@MainActor private final class FakeSession: SchedulableSession {
    var isMonitoring = false
    var isScheduleOwned = false
    var startCount = 0, stopCount = 0
    var permissionRequestCount = 0
    // Task 4: armed-idle watch surface.
    var usableDevice = true
    var deviceName: String? = "Scarlett 2i2"
    var armedDeviceMissing = false
    func startScheduled() { startCount += 1; isMonitoring = true; isScheduleOwned = true }
    func stopScheduled() { stopCount += 1; isMonitoring = false; isScheduleOwned = false }
    func requestMicrophonePermissionForSchedule() { permissionRequestCount += 1 }
    func hasUsableSelectedDevice() -> Bool { usableDevice }
    func selectedDeviceDisplayName() -> String? { deviceName }
}

/// Stands in for `SystemUserNotifier` in scheduler tests -- mirrors the fake
/// in `UserNotifyingTests.swift` (kept separate/private to each file rather
/// than shared, to keep each test file self-contained). Also mirrors
/// `SystemUserNotifier`'s permanent, never-cleared per-`id` dedupe (a `post`
/// call whose `id` was already delivered is silently dropped): this is what
/// makes `testArmedIdleDeviceMissingPostsOnceAndClearsOnReturn` a real guard
/// against `MonitoringScheduler` reusing one stable id across episodes --
/// with a naive fake that just appended every call, a regression back to a
/// stable id would go undetected here even though it would silently swallow
/// every notification after the first in production.
@MainActor private final class FakeNotifier: UserNotifying {
    private(set) var posts: [(title: String, body: String, id: String)] = []
    private(set) var authorizationRequestCount = 0
    private var postedIDs: Set<String> = []
    func requestAuthorization() async { authorizationRequestCount += 1 }
    func post(title: String, body: String, id: String) {
        guard postedIDs.insert(id).inserted else { return }
        posts.append((title: title, body: body, id: id))
    }
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

// MARK: - Task 4: notification authorization on enable

@MainActor @Test func testEnablingScheduleRequestsNotificationAuthorization() async {
    let f = FakeSession()
    let n = FakeNotifier()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    // Start disabled: nothing requested at init.
    MonitoringSchedule(isEnabled: false, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, notifier: n, now: { at(0, 0) })
    #expect(n.authorizationRequestCount == 0)

    // Checking the box activates the schedule and secures notification
    // authorization up front, alongside the existing mic-permission request.
    sch.schedule.isEnabled = true
    // requestAuthorization() is fired from a Task inside activate() (it's
    // async), so it hasn't necessarily run yet at the instant the didSet
    // above returns -- yield to let it land.
    await Task.yield()
    await Task.yield()
    #expect(n.authorizationRequestCount == 1)
}

@MainActor @Test func testLaunchWithScheduleEnabledRequestsNotificationAuthorization() async {
    let f = FakeSession()
    let n = FakeNotifier()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, notifier: n, now: { at(0, 0) })
    _ = sch                            // activate() at init requests too
    await Task.yield()
    await Task.yield()
    #expect(n.authorizationRequestCount == 1)
}

// MARK: - Task 4: armed-idle device watch

/// Armed (schedule enabled) + idle (nothing running) + the selected device
/// goes missing -> one deduped notification and a banner flag, both fired
/// via the `deviceAvailabilityChanged()` hook (what real Core Audio topology
/// changes are wired to -- see `MonitoringSession.onDeviceAvailabilityChange`).
/// Repeated ticks/changes while still missing must not pile up duplicate
/// posts; the device returning clears the banner (and re-arms the dedupe).
///
/// Also guards against a real production bug: `SystemUserNotifier` dedupes
/// posted `id`s for the life of the process and never clears them, so if the
/// scheduler reused one stable id across episodes, only the FIRST
/// disappear-episode of the app's lifetime would ever actually notify the
/// user -- every later disappear -> reconnect -> disappear cycle would
/// re-arm the in-app banner but silently post nothing. `FakeNotifier` here
/// mirrors that permanent per-id dedupe, so this test would fail against
/// that stable-id behavior: the second episode's assertions below require
/// both a second delivered post AND a distinct id from the first.
@MainActor @Test func testArmedIdleDeviceMissingPostsOnceAndClearsOnReturn() {
    let f = FakeSession()
    let n = FakeNotifier()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    // Constructed outside the window so activate()'s catch-up evaluate
    // doesn't start anything -- session stays idle throughout.
    let sch = MonitoringScheduler(session: f, defaults: d, notifier: n, now: { at(0, 0) })
    #expect(!f.isMonitoring)
    #expect(!f.armedDeviceMissing)

    // The device disappears.
    f.usableDevice = false
    sch.deviceAvailabilityChanged()
    #expect(f.armedDeviceMissing)
    #expect(n.posts.count == 1)
    #expect(n.posts[0].id == "armed-idle.device-missing.1")
    #expect(n.posts[0].body == "Scheduled input 'Scarlett 2i2' is unavailable — reconnect before the next window.")

    // Repeated signals while still missing (ticks, redundant device-change
    // notifications) must not post again.
    sch.deviceAvailabilityChanged()
    sch.evaluate(now: at(0, 1))
    #expect(n.posts.count == 1)
    #expect(f.armedDeviceMissing)

    // The device returns.
    f.usableDevice = true
    sch.deviceAvailabilityChanged()
    #expect(!f.armedDeviceMissing)
    #expect(n.posts.count == 1)               // no new post just for recovering

    // Missing again -- a genuinely NEW episode must alert again, i.e. must
    // be DELIVERED (not just re-arm the banner) even against a notifier that
    // permanently dedupes by id for the process lifetime. That requires this
    // second episode's post to carry an id distinct from the first.
    f.usableDevice = false
    sch.deviceAvailabilityChanged()
    #expect(f.armedDeviceMissing)
    #expect(n.posts.count == 2)
    #expect(n.posts[1].id == "armed-idle.device-missing.2")
    #expect(n.posts[1].id != n.posts[0].id)
}

/// While a scheduler-owned session IS running, the armed-idle watch must
/// stay quiet even if `hasUsableSelectedDevice()` would say false -- that
/// case is a mid-session disconnect, handled entirely by
/// `MonitoringSession.handleDeviceChange()`'s pause/resume path, not this.
@MainActor @Test func testArmedIdleWatchDoesNothingWhileMonitoring() {
    let f = FakeSession()
    let n = FakeNotifier()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, notifier: n, now: { at(10, 0) })
    #expect(f.isMonitoring)                   // catch-up start, mid-window

    f.usableDevice = false
    sch.deviceAvailabilityChanged()
    #expect(!f.armedDeviceMissing)
    #expect(n.posts.isEmpty)
}

/// Disabling the schedule while armed-idle-missing must clear the banner
/// (there is no longer an armed window to warn about).
@MainActor @Test func testDisablingScheduleClearsArmedIdleBanner() {
    let f = FakeSession()
    let n = FakeNotifier()
    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: f, defaults: d, notifier: n, now: { at(0, 0) })
    f.usableDevice = false
    sch.deviceAvailabilityChanged()
    #expect(f.armedDeviceMissing)

    sch.schedule.isEnabled = false
    #expect(!f.armedDeviceMissing)
}

// MARK: - Task 4: blocked-start notification, driven through a real MonitoringSession

private struct SchedulerFakeEnumerator: InputDeviceEnumerating {
    var devices: [AudioInputDevice]
    func available() -> [AudioInputDevice] { devices }
    func systemDefaultUID() -> String? { nil }
}

private func schedulerTestFreshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "bw-scheduler-test-\(UUID().uuidString)")!
}

/// A scheduled rising edge with no device ever chosen must route through
/// `MonitoringSession.start(bySchedule:)`'s blocked-start guard (Task 2)
/// rather than starting capture, AND must alert via the injected notifier --
/// nobody is watching the app to see `startBlockedReason` on an unattended
/// scheduled run. Drives a REAL `MonitoringSession` (not `FakeSession`) since
/// the posting itself lives inside `start(bySchedule:)`, not in the scheduler.
/// The SAME notifier is shared between session and scheduler, exactly as
/// `AppDelegate` wires production; the "nothing ever chosen" case here never
/// engages the armed-idle watch at all (it only tracks a chosen-but-absent
/// device -- see `selectedDeviceDisplayName()`), so this test stays at one
/// post regardless. The sibling test below (chosen-but-absent) is the one
/// that actually exercises -- and, before the `justAttemptedStart` guard in
/// `evaluate(now:)`, would have failed on -- the double-post race.
@MainActor @Test func testScheduledRisingEdgeWithNoDeviceChosenPostsBlockedNotification() async throws {
    let notifier = FakeNotifier()
    let session = MonitoringSession(deviceEnumerator: SchedulerFakeEnumerator(devices: []),
                                     defaults: schedulerTestFreshDefaults(),
                                     notifier: notifier)
    #expect(!session.hasUsableSelectedDevice())

    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    let sch = MonitoringScheduler(session: session, defaults: d, notifier: notifier, now: { at(0, 0) })

    sch.evaluate(now: at(6, 0))                     // rising edge -> startScheduled()
    // startScheduled() spawns `Task { await start(bySchedule: true) }` --
    // give it a moment to actually run before asserting.
    try await Task.sleep(for: .milliseconds(50))

    #expect(!session.isRunning)
    #expect(session.startBlockedReason == .noDeviceSelected)
    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].id == ScheduledStartBlockReason.noDeviceSelected.notificationID)
}

/// Same rising edge, but a device WAS chosen and is currently absent: the
/// session enters the awaiting-reconnect state (still `isRunning`, no
/// capture opened -- see `ScheduledStartDeviceTests.swift`) and alerts with
/// the device-unavailable copy instead.
///
/// Constructed directly MID-window (`now: { at(6, 0) }`), so the scheduler's
/// OWN catch-up `evaluate(now:)` inside `activate()` is what fires the rising
/// edge -- there is no earlier, separate "armed but before the window" moment
/// in this test. This isolates the specific race `evaluate(now:)`'s
/// `justAttemptedStart` guard exists for: on that very first catch-up call,
/// `session.isMonitoring` is still false (real `startScheduled()` is
/// fire-and-forget) and the device is already known absent, so WITHOUT the
/// guard the armed-idle watch would also fire on that same call -- moments
/// before the async `start(bySchedule:)` Task posts its own blocked-start
/// notification for the identical instant. With the guard, only the
/// blocked-start alert (below) fires; the armed-idle watch gets its turn on
/// the next tick if the device is still absent then.
@MainActor @Test func testScheduledRisingEdgeWithDeviceAbsentPostsBlockedNotification() async throws {
    let defaults = schedulerTestFreshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    defaults.set("Saved Mic", forKey: MonitoringSession.inputDeviceNameDefaultsKey)
    let notifier = FakeNotifier()
    let session = MonitoringSession(deviceEnumerator: SchedulerFakeEnumerator(devices: []),
                                     defaults: defaults, notifier: notifier)
    #expect(!session.hasUsableSelectedDevice())
    session.isRecordingEnabled = false   // no coordinator needed for this assertion

    let (d, cleanupDefaults) = freshDefaults()
    defer { cleanupDefaults() }
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60).save(to: d)
    // Same notifier shared between session and scheduler, exactly as
    // `AppDelegate` wires production.
    let sch = MonitoringScheduler(session: session, defaults: d, notifier: notifier, now: { at(6, 0) })
    _ = sch   // catch-up rising edge fires inside init/activate()

    try await Task.sleep(for: .milliseconds(50))

    #expect(session.isRunning)                       // awaiting, not stopped
    #expect(session.captureConnection == .awaitingReconnect(deviceName: "Saved Mic"))
    // Exactly one post: the blocked-start alert. Without the
    // `justAttemptedStart` guard in `evaluate(now:)`, the armed-idle watch
    // would ALSO fire on this same catch-up call (see the doc comment above)
    // and this would be 2.
    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].id == ScheduledStartBlockReason.deviceUnavailable(name: "Saved Mic").notificationID)

    session.stop()
}
