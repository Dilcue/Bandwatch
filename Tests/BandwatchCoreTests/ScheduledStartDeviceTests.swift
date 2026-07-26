import Testing
import Foundation
@testable import BandwatchCore

// Task 2: start-time presence check + at-start awaiting path.
//
// The bug: start() used to pass `selectedInputDeviceUID` straight to
// `startCapture` even when it was nil for the "chosen device currently
// absent" reason (Task 1 made that case distinguishable via
// `hasUsableSelectedDevice()`/`persistedInputUID`) -- silently opening the
// OS default (the built-in mic) instead of waiting for the real chosen
// device to come back. These tests pin down: (1) a chosen-but-absent device
// at start time enters an awaiting state with NO capture opened, a
// `.deviceLost` gap, and `isRunning == true`; (2) nothing-ever-chosen at
// start time never runs and instead surfaces `startBlockedReason`; (3) the
// ordinary present-device path is unchanged; (4) the device returning from
// the at-start-absent awaiting state auto-resumes onto the REAL device, not
// a stale nil.

private struct FakeEnumerator: InputDeviceEnumerating {
    var devices: [AudioInputDevice]
    var defaultUID: String?
    func available() -> [AudioInputDevice] { devices }
    func systemDefaultUID() -> String? { defaultUID }
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
    func simulateChange(newDevices: [AudioInputDevice]) {
        devices = newDevices
        onChange?()
    }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "bandwatch-test-\(UUID().uuidString)")!
}

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bw-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let board = AudioInputDevice(uid: "board-uid", name: "USB Audio CODEC")
private let mic = AudioInputDevice(uid: "mic-uid", name: "USB Lavalier")

/// A real, currently-present device on this machine, so the "device present"
/// path can drive an actual `AudioCaptureEngine.start()` (a fake UID does not
/// resolve to a live `AudioDeviceID` and would throw `.noInputDevice`).
private func realPresentDevice() -> AudioInputDevice? {
    CoreAudioInputDevices().available().first
}

// MARK: - Chosen device absent at start time

@MainActor
@Test func testScheduledStartWithPinnedDeviceAbsentAwaitsWithoutOpeningCapture() async throws {
    let defaults = freshDefaults()
    defaults.set("mic-uid", forKey: MonitoringSession.inputDeviceDefaultsKey)
    defaults.set("Saved Mic", forKey: MonitoringSession.inputDeviceNameDefaultsKey)
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")   // mic absent
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(!s.hasUsableSelectedDevice())

    let root = tempRoot()
    s.recordingRoot = root

    await s.start(bySchedule: true)

    #expect(s.isRunning)                                     // awaiting, not stopped
    #expect(!s.hasAnalysisTaskForTesting)                    // no capture opened
    #expect(s.latestFrame == nil)
    #expect(s.captureConnection == .awaitingReconnect(deviceName: "Saved Mic"))
    #expect(s.startBlockedReason == nil)                     // this is NOT the "nothing chosen" case

    // Let the detached openGap Task reach the actor.
    try await Task.sleep(for: .milliseconds(50))
    let store = try EventStore(readOnlyURL: RecordingPaths(root: root).databaseURL)
    let deviceLostGaps = try store.allGaps().filter { $0.reason == .deviceLost }
    #expect(deviceLostGaps.count == 1)
    #expect(deviceLostGaps[0].endedAt == nil)                // still open

    s.stop()
    try await Task.sleep(for: .milliseconds(50))
}

// MARK: - Nothing ever chosen at start time

@MainActor
@Test func testManualStartWithNoDeviceChosenNeverRunsAndSignalsUI() async {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(!s.hasUsableSelectedDevice())

    await s.start(bySchedule: false)

    #expect(!s.isRunning)
    #expect(!s.hasAnalysisTaskForTesting)
    #expect(s.captureConnection == .connected)               // never touched .awaitingReconnect
    #expect(s.startBlockedReason == .noDeviceSelected)
}

@MainActor
@Test func testScheduledStartWithNoDeviceChosenNeverRuns() async {
    let enumr = FakeEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: freshDefaults())
    #expect(!s.hasUsableSelectedDevice())

    await s.start(bySchedule: true)

    #expect(!s.isRunning)
    #expect(s.startBlockedReason == .noDeviceSelected)
}

// MARK: - Present-device path is unchanged

@MainActor
@Test func testStartWithDevicePresentIsUnchanged() async {
    guard AudioCaptureEngine.currentPermission() == .granted else { return }
    guard let device = realPresentDevice() else { return }

    let defaults = freshDefaults()
    defaults.set(device.uid, forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = FakeEnumerator(devices: [device], defaultUID: device.uid)
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.hasUsableSelectedDevice())

    s.isRecordingEnabled = false
    s.recordingRoot = tempRoot()

    await s.start(bySchedule: true)

    #expect(s.isRunning)
    #expect(s.hasAnalysisTaskForTesting)
    #expect(s.captureConnection == .connected)
    #expect(s.startBlockedReason == nil)

    s.stop()
}

// MARK: - The pinned device returning from the at-start-absent awaiting state

@MainActor
@Test func testDeviceReturningFromAtStartAbsentAwaitingResumesOnTheRealDevice() async throws {
    guard AudioCaptureEngine.currentPermission() == .granted else { return }
    guard let device = realPresentDevice() else { return }

    let defaults = freshDefaults()
    defaults.set(device.uid, forKey: MonitoringSession.inputDeviceDefaultsKey)
    defaults.set(device.name, forKey: MonitoringSession.inputDeviceNameDefaultsKey)
    // The pinned device is ABSENT at start time -- only `board` is enumerated.
    let enumr = MutableEnumerator(devices: [board], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(!s.hasUsableSelectedDevice())

    let root = tempRoot()
    s.recordingRoot = root

    await s.start(bySchedule: true)
    #expect(s.isRunning)
    #expect(!s.hasAnalysisTaskForTesting)
    #expect(s.captureConnection == .awaitingReconnect(deviceName: device.name))
    // The bug this guards against: selectedInputDeviceUID must still be nil
    // here (the device is absent) -- if resumeAfterReconnect blindly reused
    // this, it would target nil (the built-in mic), not the real device.
    #expect(s.selectedInputDeviceUID == nil)

    try await Task.sleep(for: .milliseconds(50))   // let the openGap Task land

    // The device physically returns.
    enumr.simulateChange(newDevices: [board, device])

    #expect(s.captureConnection == .connected)
    #expect(s.hasAnalysisTaskForTesting)                     // real capture came up
    // Resolution must have re-pinned the effective selection to the device
    // that is now actually capturing, not left it at the stale nil.
    #expect(s.selectedInputDeviceUID == device.uid)

    try await Task.sleep(for: .milliseconds(50))             // let closeGap land
    s.stop()
    try await Task.sleep(for: .milliseconds(50))

    let store = try EventStore(readOnlyURL: RecordingPaths(root: root).databaseURL)
    let deviceLostGaps = try store.allGaps().filter { $0.reason == .deviceLost }
    #expect(deviceLostGaps.count == 1)
    #expect(deviceLostGaps[0].endedAt != nil)                // closed by the resume, not left open
}

/// Existing mid-session disconnect -> resume path (a running, CONNECTED
/// capture whose pinned device then vanishes and returns) must keep working
/// after adding `resolveInputSelection()` to the `.resume` branch --
/// `selectedInputDeviceUID` was already correctly pinned in this case, and
/// re-resolving it while the device is present must be a no-op, not a
/// regression.
@MainActor
@Test func testMidSessionReconnectStillResumesOnThePinnedDevice() async throws {
    guard AudioCaptureEngine.currentPermission() == .granted else { return }
    guard let device = realPresentDevice() else { return }

    let defaults = freshDefaults()
    defaults.set(device.uid, forKey: MonitoringSession.inputDeviceDefaultsKey)
    let enumr = MutableEnumerator(devices: [board, device], defaultUID: "board-uid")
    let s = MonitoringSession(deviceEnumerator: enumr, defaults: defaults)
    #expect(s.selectedInputDeviceUID == device.uid)

    s.isRecordingEnabled = false
    s.recordingRoot = tempRoot()
    await s.start(bySchedule: false)
    #expect(s.isRunning)
    #expect(s.hasAnalysisTaskForTesting)

    enumr.simulateChange(newDevices: [board])                // pinned device unplugged
    #expect(s.captureConnection == .awaitingReconnect(deviceName: device.name))
    #expect(!s.hasAnalysisTaskForTesting)

    enumr.simulateChange(newDevices: [board, device])        // pinned device returns
    #expect(s.captureConnection == .connected)
    #expect(s.hasAnalysisTaskForTesting)
    #expect(s.selectedInputDeviceUID == device.uid)

    s.stop()
}
