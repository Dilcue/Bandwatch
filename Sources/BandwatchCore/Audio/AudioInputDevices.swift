import Foundation
import CoreAudio

/// One selectable audio input device. `uid` is the stable identifier we persist
/// and record as evidence; the Core Audio `AudioDeviceID` is deliberately NOT
/// stored, because it is not stable across unplug/replug — it is resolved from
/// the `uid` at capture time (`CoreAudioInputDevices.deviceID(forUID:)`).
public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Discovery of input devices, abstracted so `MonitoringSession`'s selection /
/// persistence / fallback logic can be unit-tested with a fake device list —
/// the real implementation talks to Core Audio hardware, which tests can't.
public protocol InputDeviceEnumerating: Sendable {
    /// All current input-capable devices, in system order.
    func available() -> [AudioInputDevice]
    /// Begin observing hardware topology changes. `onChange` is invoked
    /// whenever the set of input devices may have changed. Delivery thread is
    /// implementation-defined; consumers must hop to their own isolation.
    func startObserving(onChange: @escaping @Sendable () -> Void)
    func stopObserving()
}

public extension InputDeviceEnumerating {
    // Default no-ops: a static/fake enumerator that never changes need not
    // implement observation. Only CoreAudioInputDevices (real hardware) and
    // test fakes that exercise change events override these.
    func startObserving(onChange: @escaping @Sendable () -> Void) {}
    func stopObserving() {}
}

/// Core Audio (HAL) implementation of input-device discovery. Approach verified
/// by spike 2026-07-23 (see the M6 design spec).
///
/// `@unchecked Sendable`: `listenerBlock`/`listenerAddress` below are mutable,
/// which the compiler can't statically prove safe for a `Sendable`-conforming
/// class. In practice they're never touched concurrently -- each
/// `MonitoringSession` owns exactly one instance and calls `startObserving`
/// once (from its `init`) and `stopObserving` once (from its `deinit`), with
/// no other access in between. Same reasoning/pattern as the `MutableEnumerator`
/// test fake.
public final class CoreAudioInputDevices: InputDeviceEnumerating, @unchecked Sendable {
    public init() {}

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public func startObserving(onChange: @escaping @Sendable () -> Void) {
        stopObserving()
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, block)
    }

    public func stopObserving() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listenerAddress, DispatchQueue.main, block)
        listenerBlock = nil
    }

    deinit { stopObserving() }

    public func available() -> [AudioInputDevice] {
        Self.allDeviceIDs().compactMap { id in
            guard Self.hasInputStreams(id),
                  let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Resolves a saved UID to a live device ID, or nil if the device is not
    /// currently present (which drives the fallback-to-default behavior).
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() where hasInputStreams(id) {
            if stringProperty(id, kAudioDevicePropertyDeviceUID) == uid { return id }
        }
        return nil
    }

    // MARK: Core Audio HAL

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// True when the system's current default **output** device is a Multi-Output
    /// or Aggregate device (both report the aggregate transport type). This is a
    /// known macOS cause of input-capture stalls: AVAudioEngine still runs an
    /// output I/O unit on the default output device even for an input-only app,
    /// and it cannot drive an aggregate output — starving the input tap until the
    /// stall watchdog halts monitoring. Used only to tailor the stall message.
    /// Fails closed (false) when the default output can't be read, so we never
    /// blame a device we did not actually confirm.
    public static func defaultOutputIsAggregate() -> Bool {
        guard let id = defaultOutputDeviceID(),
              let transport = transportType(of: id) else { return false }
        return isAggregateTransport(transport)
    }

    /// Pure transport-type classifier, factored out so the decision is testable
    /// without real aggregate hardware.
    static func isAggregateTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeAggregate
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buf in abl { channels += Int(buf.mNumberChannels) }
        return channels > 0
    }

    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v as String
    }
}
