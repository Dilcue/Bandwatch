import Testing
import Foundation
@testable import BandwatchCore

private struct FakeEnumerator: InputDeviceEnumerating {
    var devices: [AudioInputDevice]
    var defaultUID: String?
    func available() -> [AudioInputDevice] { devices }
    func systemDefaultUID() -> String? { defaultUID }
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

@MainActor @Test func testSavedDeviceAbsentFallsBackToDefaultWithNotice() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)   // lav mic saved…
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")       // …but unplugged
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == nil)                       // fell back to System Default
    #expect(s.inputNotice != nil)                                  // and said so
    // Preference is NOT cleared, so it re-selects when the device returns.
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == "mic-uid")
}

@MainActor @Test func testNoSavedDeviceDefaultsToSystemDefault() {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)
    #expect(s.inputNotice == nil)
}

@MainActor @Test func testSelectingADevicePersistsAndClearing() {
    let defaults = freshDefaults()
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)

    s.selectedInputDeviceUID = "mic-uid"
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == "mic-uid")

    s.selectedInputDeviceUID = nil                                 // back to System Default
    #expect(defaults.string(forKey: MonitoringSession.inputDeviceDefaultsKey) == nil)
}

@MainActor @Test func testRecordingDeviceUIDIsSelectedWhenPresent() {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [board, mic], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.recordingDeviceUID() == "mic-uid")
}

@MainActor @Test func testRecordingDeviceUIDIsSystemDefaultWhenFollowingOS() {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)
    #expect(s.recordingDeviceUID() == "board-uid")                 // the OS default's UID
}

@MainActor @Test func testRecordingDeviceUIDFallsToDefaultIfSelectedVanishes() {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    s.selectedInputDeviceUID = "ghost-uid"                         // selected, but not present
    #expect(s.recordingDeviceUID() == "board-uid")                // records what actually captures
}

private final class MutableEnumerator: InputDeviceEnumerating, @unchecked Sendable {
    var devices: [AudioInputDevice]
    var defaultUID: String?
    private var onChange: (@Sendable () -> Void)?
    init(devices: [AudioInputDevice], defaultUID: String?) {
        self.devices = devices; self.defaultUID = defaultUID
    }
    func available() -> [AudioInputDevice] { devices }
    func systemDefaultUID() -> String? { defaultUID }
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

@MainActor @Test func testSystemDefaultDisconnectDoesNotPause() async {
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(s.selectedInputDeviceUID == nil)             // System Default
    await s.startRecordingForTesting(root: tempRoot())

    enumr.simulateChange(newDevices: [])                 // default device vanishes

    #expect(s.captureConnection == .connected)           // follows the OS; no pause
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
