import Testing
import Foundation
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
