import Testing
import Foundation
@testable import BandwatchCore

private struct FakeEnumerator: InputDeviceEnumerating {
    var devices: [AudioInputDevice]
    var defaultUID: String?
    func available() -> [AudioInputDevice] { devices }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "bandwatch-test-\(UUID().uuidString)")!
}

private let mic = AudioInputDevice(uid: "mic-uid", name: "USB Lavalier")
private let board = AudioInputDevice(uid: "board-uid", name: "USB Audio CODEC")

@MainActor @Test func testSavedDevicePresentIsSelected() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == "mic-uid")
    #expect(s.inputNotice == nil)
    #expect(s.availableInputDevices == [board, mic])
}

@MainActor @Test func testSavedDeviceAbsentHasNoUsableSelectionAndNamesItInTheNotice() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)   // lav mic saved…
    defaults.set("Saved Mic", forKey: MonitoringSession.inputDeviceNameDefaultsKey)
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")       // …but unplugged
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == nil)                       // no usable device — NOT a fallback
    #expect(s.inputNotice == "Selected input 'Saved Mic' is unavailable — reconnect it or choose another.")
    #expect(s.hasUsableSelectedDevice() == false)
    // Preference is NOT cleared, so it re-selects when the device returns.
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == "mic-uid")
}

@MainActor @Test func testNoSavedDeviceMeansNoneChosen() {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)
    #expect(s.inputNotice == nil)
    #expect(s.hasUsableSelectedDevice() == false)
}

@MainActor @Test func testSavedDevicePresentIsUsable() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.hasUsableSelectedDevice() == true)
}

@MainActor @Test func testSelectingADevicePersistsUIDAndNameAndClearing() {
    let defaults = freshDefaults()
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)

    s.selectedInputDeviceUID = "mic-uid"
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == "mic-uid")
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceNameDefaultsKey) == "USB Lavalier")

    s.selectedInputDeviceUID = nil                                 // cleared — none chosen
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == nil)
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceNameDefaultsKey) == nil)
}

@MainActor @Test func testRecordingDeviceUIDIsSelectedWhenPresent() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.recordingDeviceUID() == "mic-uid")
}

@MainActor @Test func testRecordingDeviceUIDNeverFallsBackToSystemDefaultWhenNoneChosen() {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)
    // No device ever chosen and no pinned preference — returns the documented
    // placeholder instead of falling back to system default.
    #expect(s.recordingDeviceUID() == "unknown")
}

@MainActor @Test func testRecordingDeviceUIDPinsToPreferenceIfSelectedVanishesRatherThanSystemDefault() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")      // mic absent
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == nil)                       // no usable device
    // Must never return the enumerator's system-default UID ("board-uid") — it
    // falls back to the pinned preference instead.
    #expect(s.recordingDeviceUID() == "mic-uid")
}

private final class MutableEnumerator: InputDeviceEnumerating, @unchecked Sendable {
    var devices: [AudioInputDevice]
    var defaultUID: String?
    private var onChange: (@Sendable () -> Void)?
    init(devices: [AudioInputDevice], defaultUID: String?) {
        self.devices = devices; self.defaultUID = defaultUID
    }
    func available() -> [AudioInputDevice] { devices }
    func startObserving(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }
    /// Swap the device list and fire the observer, as a hot-plug would.
    func simulateChange(newDevices: [AudioInputDevice]) {
        devices = newDevices
        onChange?()
    }
}

@MainActor @Test func testRefreshInputDevicesRereadsList() {
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.availableInputDevices == [board])
    enumr.devices = [board, mic]                                   // lav mic plugged in
    s.refreshInputDevices()
    #expect(s.availableInputDevices == [board, mic])
}

/// The persistence bug: the saved device isn't enumerated at the instant the
/// session is created (early app launch), so init falls back to System Default.
/// The picker's onAppear refresh must then RE-RESOLVE and select the saved
/// device once it appears — otherwise the choice looks like it didn't persist.
@MainActor @Test func testSavedDeviceRecoversOnRefreshWhenItAppears() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [], defaultUID: "board-uid")   // nothing enumerated yet
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == nil)                     // transient fallback at init
    #expect(s.inputNotice != nil)

    enumr.devices = [board, mic]                                 // list becomes ready
    s.refreshInputDevices()
    #expect(s.selectedInputDeviceUID == "mic-uid")               // recovered the saved choice
    #expect(s.inputNotice == nil)
    // The preference was never lost from persistence during the transient fallback.
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == "mic-uid")
}

@MainActor @Test func testHardwareChangeLiveRefreshesDropdown() {
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.availableInputDevices == [board])
    enumr.simulateChange(newDevices: [board, mic])   // mic plugged in, no manual refresh
    #expect(s.availableInputDevices == [board, mic])
}

/// Evidence-integrity regression: the pinned device is absent at launch (transient
/// fallback to System Default), then reconnects while the session is NOT running,
/// without the picker ever being opened (so `refreshInputDevices()` never fires).
/// The live Core Audio observer's `.refreshOnly` path must itself re-resolve the
/// selection when stopped -- otherwise `selectedInputDeviceUID` stays nil even
/// though the dropdown now lists the pinned device, and a subsequent Start would
/// silently capture System Default (the built-in mic) instead of the trusted,
/// pinned input.
@MainActor @Test func testPinnedDeviceReconnectingWhileStoppedIsReselected() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")   // mic absent at launch
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == nil)                 // transient fallback
    #expect(s.inputNotice != nil)

    enumr.simulateChange(newDevices: [board, mic])           // mic reconnects while STOPPED

    #expect(s.selectedInputDeviceUID == "mic-uid")           // live observer recovered the pinned choice
    #expect(s.inputNotice == nil)
}

/// Hardware-verification regression: the user's chosen device (board, "USB
/// Audio CODEC") goes missing, leaving a stale `inputNotice` naming it. The
/// user then picks a DIFFERENT, available device (mic) from the picker.
/// `resolveInputSelection` -- the notice's only other writer -- never runs on
/// this user-pick path, so before the fix the notice about the OLD device
/// persisted even though the picker only ever lists available devices (a
/// user pick, by construction, resolves any "unavailable" condition).
@MainActor @Test func testSelectingDifferentDeviceClearsStaleInputNotice() {
    let defaults = freshDefaults()
    defaults.set("board-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    defaults.set("USB Audio CODEC", forKey: MonitoringSession.inputDeviceNameDefaultsKey)
    let enumr = MutableEnumerator(devices: [], defaultUID: nil)   // board unplugged at launch
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.inputNotice == "Selected input 'USB Audio CODEC' is unavailable — reconnect it or choose another.")

    enumr.devices = [mic]            // a different device (mic) shows up
    s.refreshInputDevices()
    #expect(s.inputNotice != nil)    // board is still absent -- notice persists

    s.selectedInputDeviceUID = "mic-uid"   // user picks the available mic instead
    #expect(s.inputNotice == nil)
}

/// The scheduler's armed-idle watch only re-evaluates when
/// `onDeviceAvailabilityChange` fires -- wired to a hardware topology change
/// via `handleDeviceChange()`, but never fired by a user picking a new
/// device from the picker before this fix. Without it, `armedDeviceMissing`
/// (and its banner) stays stuck true until the next 30s tick even after the
/// user resolves the problem by hand.
@MainActor @Test func testSelectingDeviceFiresAvailabilityChangeHook() {
    let defaults = freshDefaults()
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    var fired = false
    s.onDeviceAvailabilityChange = { fired = true }

    s.selectedInputDeviceUID = "mic-uid"

    #expect(fired)
}

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor @Test func testPinnedDisconnectPausesAndWarns() async {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == "mic-uid")
    await s.startRecordingForTesting(root: tempRoot())

    enumr.simulateChange(newDevices: [board])            // the pinned mic is unplugged

    #expect(s.captureConnection == .awaitingReconnect(deviceName: "USB Lavalier"))
    #expect(s.isRunning)                                 // paused, NOT stopped
    #expect(s.latestFrame == nil)                        // no frozen spectrum reads as live
    s.stop()
}

@MainActor @Test func testNoChosenDeviceSessionDoesNotPauseOnDisconnect() async {
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)             // no device has been chosen (persistedInputUID == nil)
    await s.startRecordingForTesting(root: tempRoot())

    enumr.simulateChange(newDevices: [])                 // device list changes

    #expect(s.captureConnection == .connected)           // no pinned device to lose; device-list change yields .refreshOnly
    #expect(s.isRunning)
    s.stop()
}

@MainActor @Test func testPinnedDisconnectPersistsDeviceLostGap() async throws {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    let root = tempRoot()
    await s.startRecordingForTesting(root: root)

    enumr.simulateChange(newDevices: [board])            // disconnect → opens gap
    // Let the detached openGap Task reach the actor.
    try await Task.sleep(for: .milliseconds(50))
    s.stop()
    try await Task.sleep(for: .milliseconds(50))         // let stop()'s teardown finish

    let store = try EventStore(readOnlyURL:
        RecordingPaths(root: root).databaseURL)
    let gaps = try store.allGaps()
    #expect(gaps.contains { $0.reason == .deviceLost })
}

@MainActor @Test func testReconnectResumesAndClosesGap() async throws {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    let root = tempRoot()
    await s.startRecordingForTesting(root: root)

    enumr.simulateChange(newDevices: [board])            // disconnect
    #expect(s.captureConnection == .awaitingReconnect(deviceName: "USB Lavalier"))
    try await Task.sleep(for: .milliseconds(50))         // let openGap land

    enumr.devices = [board, mic]                         // device physically back
    s.resumeForTesting()                                 // logical resume (no real engine)
    #expect(s.captureConnection == .connected)
    try await Task.sleep(for: .milliseconds(50))         // let closeGap land

    s.stop()
    try await Task.sleep(for: .milliseconds(50))
    let store = try EventStore(readOnlyURL: RecordingPaths(root: root).databaseURL)
    let deviceLost = try store.allGaps().filter { $0.reason == .deviceLost }
    #expect(deviceLost.count == 1)
    #expect(deviceLost[0].endedAt != nil)                // closed by resume, not left open
}

@MainActor @Test func testResumeDecisionIgnoresDifferentDevice() async {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    await s.startRecordingForTesting(root: tempRoot())

    enumr.simulateChange(newDevices: [board])            // pinned mic gone → awaiting
    #expect(s.captureConnection == .awaitingReconnect(deviceName: "USB Lavalier"))

    let other = AudioInputDevice(uid: "other-uid", name: "Some Other Mic")
    // A DIFFERENT device appears; the pinned mic is still absent.
    #expect(s.deviceChangeAction(devices: [board, other]) == .refreshOnly)
    s.stop()
}
