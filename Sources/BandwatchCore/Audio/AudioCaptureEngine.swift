import AVFoundation
import Foundation
import CoreAudio
import AudioToolbox

public enum MicrophonePermission: Equatable, Sendable {
    case granted
    case denied
    case undetermined
}

public enum CaptureError: Error, Equatable {
    case permissionDenied
    case engineStartFailed(String)
    case noInputDevice
    /// The ring buffer stopped advancing while the session was still
    /// running — the tap callback has gone silent (device disconnect,
    /// mid-stream converter failure, etc.) but `AudioCaptureEngine` has no
    /// path to report that on its own (see the type's doc comment above).
    /// `MonitoringSession` detects the stall itself by watching
    /// `RingBuffer.totalWritten` and publishes this case so the UI stops
    /// claiming to monitor a dead microphone.
    case captureStalled
}

/// Wraps AVAudioEngine input capture, feeding samples into a RingBuffer.
///
/// The tap callback runs on the realtime audio thread: it does nothing but copy
/// samples into the ring buffer. No allocation, no locking beyond the buffer's
/// own short critical section, no I/O.
///
/// **Configuration-change recovery.** AVAudioEngine STOPS itself and posts
/// `AVAudioEngineConfigurationChange` whenever the audio hardware configuration
/// changes underneath it — most importantly when an input device is
/// unplugged/replugged. Recovering from that is the app's responsibility: this
/// class observes the notification and reconfigures + restarts the engine.
/// Without it, capture dies silently after a device reconnect and the ring
/// buffer stalls forever. The target device is held by **UID**, not the
/// CoreAudio `AudioDeviceID` (which is not stable across unplug/replug — see
/// `CoreAudioInputDevices`), and re-resolved to a live ID on every (re)start.
///
/// `@unchecked Sendable`: all of this instance's mutable state
/// (`converter`, `tapInstalled`, `isRunning`, `configObserver`,
/// `reconfiguring`) is touched only on the main thread — `start()`/`stop()`
/// are called from `MonitoringSession` (itself `@MainActor`), and the
/// configuration-change observer is delivered on `OperationQueue.main`. The
/// realtime tap closure runs on the audio thread but captures only the ring
/// buffer, converter, and formats — never `self` — so it never races this
/// state. The `@unchecked` conformance is what lets the observer closure
/// weakly capture `self` without forcing the tap block to become `@Sendable`.
public final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let ringBuffer: RingBuffer
    private let targetSampleRate: Double
    /// UID of the CoreAudio input device to capture from, or nil to follow the
    /// system default input. Held as a UID and re-resolved to a live
    /// `AudioDeviceID` at each (re)start, because the ID is not stable across
    /// unplug/replug: a value cached at first start goes stale and its selection
    /// fails ("no object with given ID") after a reconnect.
    private let targetDeviceUID: String?
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    /// A hardware hot-plug fires several `AVAudioEngineConfigurationChange`
    /// notifications in quick succession, and the engine keeps settling for a
    /// moment afterwards — restarting the instant the first notification lands
    /// gets undone ~5ms later by the still-in-flight reconfiguration (observed
    /// on a real USB reconnect). `pendingRestart` coalesces the burst and defers
    /// the restart until the hardware has quiesced.
    private var pendingRestart: DispatchWorkItem?
    private var restartRetries = 0
    /// Settle delay before (re)starting after a configuration change, and the
    /// cap on retries while the device is still coming back. 4 × 0.5s keeps the
    /// whole recovery comfortably inside `MonitoringSession`'s 3s stall window.
    private static let restartSettle: TimeInterval = 0.5
    private static let maxRestartRetries = 4

    public private(set) var isRunning = false

    public init(ringBuffer: RingBuffer, sampleRate: Double, targetDeviceUID: String? = nil) {
        self.ringBuffer = ringBuffer
        self.targetSampleRate = sampleRate
        self.targetDeviceUID = targetDeviceUID
    }

    public static func currentPermission() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        guard !isRunning else { return }
        guard Self.currentPermission() == .granted else {
            throw CaptureError.permissionDenied
        }

        try configure()
        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTap()
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }

        // Recover from hardware configuration changes (device unplug/replug,
        // sample-rate changes) — see the type doc comment. Registered only after
        // a successful start so the observer never fires against a half-built
        // graph, and delivered on the main queue to match this class's
        // main-actor isolation.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        isRunning = true
    }

    /// Selects the target device (re-resolving its UID to a live
    /// `AudioDeviceID`), reads the input format, builds the converter, and
    /// installs the tap. Shared by `start()` and `handleConfigurationChange()`.
    /// Does NOT start the engine — the caller does, so start-failure handling
    /// lives in one place.
    private func configure() throws {
        removeTap()
        let input = engine.inputNode

        // Select the requested device BEFORE reading the input format, so the
        // format (and therefore the converter) reflects the chosen device. A nil
        // target leaves the engine on the system default input. Resolve the UID
        // fresh each call — the AudioDeviceID is not stable across unplug/replug.
        if let uid = targetDeviceUID {
            guard let deviceID = CoreAudioInputDevices.deviceID(forUID: uid) else {
                throw CaptureError.noInputDevice
            }
            guard let au = input.audioUnit else {
                throw CaptureError.engineStartFailed("input node has no audio unit")
            }
            var dev = deviceID
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw CaptureError.engineStartFailed(
                    "could not select input device \(uid): OSStatus \(status)")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        // Target: mono at the configured sample rate.
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: 1
        ) else {
            throw CaptureError.engineStartFailed("could not create target format")
        }

        let needsConversion = inputFormat.sampleRate != targetSampleRate
            || inputFormat.channelCount != 1

        if needsConversion {
            // AVAudioConverter(from:to:) is documented to be able to return nil
            // for unsupported format pairs. If that happened and we left
            // `converter` nil here, the tap closure below cannot distinguish
            // "no conversion needed" from "conversion needed but unavailable" —
            // its fallback path (meant only for the former) would copy raw
            // samples at the wrong sample rate/channel count straight into the
            // ring buffer. Every frequency this app reports would then be
            // silently wrong (e.g. 44.1kHz audio analyzed as if it were 48kHz),
            // with nothing thrown and nothing logged. Fail loudly instead.
            guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw CaptureError.engineStartFailed(
                    "could not create AVAudioConverter from \(inputFormat) to \(targetFormat)"
                )
            }
            converter = conv
        } else {
            // Input is already mono at the target rate — no converter needed,
            // the tap's direct-copy fallback is correct.
            converter = nil
        }

        let buffer = ringBuffer
        let conv = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { pcm, _ in
            guard let conv else {
                // Already mono at target rate — copy directly.
                if let data = pcm.floatChannelData?[0] {
                    buffer.write(data, count: Int(pcm.frameLength))
                }
                return
            }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            var consumed = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return pcm
            }

            if error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 {
                buffer.write(data, count: Int(out.frameLength))
            }
        }
        tapInstalled = true
    }

    /// AVAudioEngine stopped itself because the audio hardware configuration
    /// changed (typically a device unplug/replug). Coalesce the burst of
    /// notifications and schedule a restart once the hardware settles — see
    /// `pendingRestart`.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        restartRetries = 0
        scheduleRestart()
    }

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAfterConfigurationChange() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartSettle, execute: work)
    }

    /// Reconfigure against the CURRENT device topology and restart. Runs after
    /// the settle delay, on the main thread. If the engine already came back on
    /// its own, do nothing. If the device is still settling (e.g. a USB port
    /// re-enumerating) `configure()`/`start()` throws and we retry a bounded
    /// number of times; if it is genuinely gone (a real disconnect, which
    /// `MonitoringSession` handles by pausing) we exhaust the retries and leave
    /// the engine stopped — the session's ring-buffer stall detector is the
    /// backstop. Deliberately never flips `isRunning`.
    private func restartAfterConfigurationChange() {
        guard isRunning, !engine.isRunning else { return }
        do {
            try configure()
            engine.prepare()
            try engine.start()
        } catch {
            restartRetries += 1
            if restartRetries <= Self.maxRestartRetries {
                scheduleRestart()
            }
        }
    }

    public func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard isRunning || tapInstalled else { return }
        engine.stop()
        removeTap()
        isRunning = false
    }

    private func removeTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
