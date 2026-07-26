import Testing
import Foundation
import UserNotifications
@testable import BandwatchCore

// Task 3: notification client seam. `FakeNotifier` stands in for
// `SystemUserNotifier` so these tests exercise the dedupe contract and the
// reason -> copy mapping without touching `UNUserNotificationCenter` (which
// needs a real app bundle context and isn't exercised here).

@MainActor
private final class FakeNotifier: UserNotifying {
    private(set) var posts: [(title: String, body: String, id: String)] = []
    private(set) var authorizationRequestCount = 0
    private var postedIDs: Set<String> = []

    func requestAuthorization() async {
        authorizationRequestCount += 1
    }

    func post(title: String, body: String, id: String) {
        guard postedIDs.insert(id).inserted else { return }
        posts.append((title: title, body: body, id: id))
    }
}

// MARK: - post(title:body:id:) recording + dedupe

@MainActor
@Test func testPostRecordsTitleBodyID() {
    let notifier = FakeNotifier()

    notifier.post(title: "Title", body: "Body", id: "the-id")

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].title == "Title")
    #expect(notifier.posts[0].body == "Body")
    #expect(notifier.posts[0].id == "the-id")
}

@MainActor
@Test func testDuplicateIDWithinSessionDoesNotDoubleRecord() {
    let notifier = FakeNotifier()

    notifier.post(title: "First", body: "First body", id: "dup-id")
    notifier.post(title: "Second", body: "Second body", id: "dup-id")

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].title == "First")   // second post was dropped, not merged
}

@MainActor
@Test func testDifferentIDsBothRecord() {
    let notifier = FakeNotifier()

    notifier.post(title: "A", body: "A body", id: "id-a")
    notifier.post(title: "B", body: "B body", id: "id-b")

    #expect(notifier.posts.count == 2)
}

// MARK: - ScheduledStartBlockReason copy (pure, no notifier involved)

@Test func testNoDeviceSelectedCopy() {
    let reason = ScheduledStartBlockReason.noDeviceSelected

    #expect(reason.notificationTitle == "Bandwatch: Scheduled Monitoring Skipped")
    #expect(reason.notificationBody == "No input device is selected, so scheduled monitoring did not start. Open Bandwatch and choose an input device.")
    #expect(reason.notificationID == "scheduled-start-blocked.no-device-selected")
}

@Test func testDeviceUnavailableCopyNamesTheDevice() {
    let reason = ScheduledStartBlockReason.deviceUnavailable(name: "USB Lavalier")

    #expect(reason.notificationTitle == "Bandwatch: Scheduled Monitoring Skipped")
    #expect(reason.notificationBody == "The selected input device \u{201c}USB Lavalier\u{201d} is unavailable, so scheduled monitoring did not start. Reconnect it or choose another device in Bandwatch.")
    #expect(reason.notificationBody.contains("USB Lavalier"))
    #expect(reason.notificationID == "scheduled-start-blocked.device-unavailable")
}

@Test func testDeviceUnavailableIDIsStablePerReasonRegardlessOfDeviceName() {
    let a = ScheduledStartBlockReason.deviceUnavailable(name: "Mic A")
    let b = ScheduledStartBlockReason.deviceUnavailable(name: "Mic B")

    #expect(a.notificationID == b.notificationID)
}

// MARK: - post(blocked:) extension mapping

@MainActor
@Test func testPostBlockedNoDeviceSelectedMapsToItsCopy() {
    let notifier = FakeNotifier()

    notifier.post(blocked: .noDeviceSelected)

    #expect(notifier.posts.count == 1)
    let reason = ScheduledStartBlockReason.noDeviceSelected
    #expect(notifier.posts[0].title == reason.notificationTitle)
    #expect(notifier.posts[0].body == reason.notificationBody)
    #expect(notifier.posts[0].id == reason.notificationID)
}

@MainActor
@Test func testPostBlockedDeviceUnavailableMapsToItsCopy() {
    let notifier = FakeNotifier()
    let reason = ScheduledStartBlockReason.deviceUnavailable(name: "Saved Mic")

    notifier.post(blocked: reason)

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts[0].title == reason.notificationTitle)
    #expect(notifier.posts[0].body == reason.notificationBody)
    #expect(notifier.posts[0].id == reason.notificationID)
}

@MainActor
@Test func testPostBlockedRepeatedSameReasonDedupesViaStableID() {
    let notifier = FakeNotifier()

    notifier.post(blocked: .noDeviceSelected)
    notifier.post(blocked: .noDeviceSelected)

    #expect(notifier.posts.count == 1)
}

// MARK: - SystemUserNotifier: deliver-then-dedupe ordering (real class, seams injected)
//
// These exercise the real `SystemUserNotifier`, not a fake, using its
// injected `isAuthorized`/`deliver` seams in place of `UNUserNotificationCenter`.
// `post` fires an internal `Task`, so tests poll (via `waitUntil`, yielding
// rather than sleeping) for the externally-visible effect instead of assuming
// a fixed number of yields is enough.

/// Sendable snapshot of the parts of a `UNNotificationRequest` these tests
/// care about -- `UNNotificationRequest` itself isn't `Sendable`, so it can't
/// cross the actor boundary into `NotifierProbe`.
private struct DeliveredNotification: Sendable, Equatable {
    let id: String
    let title: String
    let body: String
    let hasSound: Bool
}

/// Records what `SystemUserNotifier`'s injected seams observed.
private actor NotifierProbe {
    private(set) var authorizationChecks = 0
    private(set) var delivered: [DeliveredNotification] = []
    private var nextAuthorizedResult = false

    func setAuthorized(_ value: Bool) {
        nextAuthorizedResult = value
    }

    func checkAuthorized() -> Bool {
        authorizationChecks += 1
        return nextAuthorizedResult
    }

    func recordDelivery(_ notification: DeliveredNotification) {
        delivered.append(notification)
    }

    var deliveredIDs: [String] {
        delivered.map(\.id)
    }
}

/// Spin-waits (yielding, never sleeping) until `condition` is true or the
/// deadline passes.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return }
        await Task.yield()
    }
}

@MainActor
@Test func testDeniedOnFirstAttemptDoesNotBlockLaterAuthorizedDelivery() async {
    let probe = NotifierProbe()
    let notifier = SystemUserNotifier(
        isAuthorized: { await probe.checkAuthorized() },
        deliver: { request in
            let notification = DeliveredNotification(
                id: request.identifier,
                title: request.content.title,
                body: request.content.body,
                hasSound: request.content.sound != nil
            )
            await probe.recordDelivery(notification)
        }
    )

    // First attempt: permission denied (or undetermined).
    await probe.setAuthorized(false)
    notifier.post(title: "T1", body: "B1", id: "shared-id")
    await waitUntil { await probe.authorizationChecks >= 1 }
    #expect(await probe.delivered.isEmpty)

    // Later attempt, same id, now authorized. The denied first attempt must
    // NOT have permanently marked "shared-id" as posted -- this is the bug
    // being fixed: dedupe must only latch once delivery actually happens.
    await probe.setAuthorized(true)
    notifier.post(title: "T2", body: "B2", id: "shared-id")
    await waitUntil { await probe.delivered.count >= 1 }

    #expect(await probe.deliveredIDs == ["shared-id"])
    let notification = await probe.delivered[0]
    #expect(notification.title == "T2")
    #expect(notification.body == "B2")
    #expect(notification.hasSound)
}

@MainActor
@Test func testAuthorizedSameIDTwiceWithinSessionDeliversOnce() async {
    let probe = NotifierProbe()
    let notifier = SystemUserNotifier(
        isAuthorized: { await probe.checkAuthorized() },
        deliver: { request in
            let notification = DeliveredNotification(
                id: request.identifier,
                title: request.content.title,
                body: request.content.body,
                hasSound: request.content.sound != nil
            )
            await probe.recordDelivery(notification)
        }
    )
    await probe.setAuthorized(true)

    notifier.post(title: "First", body: "First body", id: "dup-id")
    await waitUntil { await probe.delivered.count >= 1 }

    notifier.post(title: "Second", body: "Second body", id: "dup-id")
    // Let the second attempt run its course (it will re-check authorization
    // before hitting the dedupe guard) before asserting only one delivery.
    await waitUntil { await probe.authorizationChecks >= 2 }

    #expect(await probe.deliveredIDs == ["dup-id"])
    let notification = await probe.delivered[0]
    #expect(notification.title == "First")
}
