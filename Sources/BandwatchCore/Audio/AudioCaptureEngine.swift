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
/// Error reporting is honest but incomplete: failures `start()` can detect
/// up front (no permission, no input device, converter construction failure)
/// are thrown from `start()`. Failures that occur *during* capture — the
/// input device disconnecting, or the converter failing mid-stream — are not
/// yet reported to anyone. There is deliberately no delegate/callback for
/// this: this milestone has no runtime error-reporting path off the realtime
/// audio thread, and invoking a delegate from that thread would itself be
/// questionable. Reporting mid-capture failures is deferred to the later
/// milestone that handles device disconnect and retry.
public final class AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private let ringBuffer: RingBuffer
    private let targetSampleRate: Double
    /// Core Audio device to capture from, or nil to use the system default
    /// input. Resolved from a device UID by the caller — see
    /// `CoreAudioInputDevices.deviceID(forUID:)`.
    private let targetDeviceID: AudioDeviceID?
    private var converter: AVAudioConverter?
    private var tapInstalled = false

    public private(set) var isRunning = false

    public init(ringBuffer: RingBuffer, sampleRate: Double, targetDeviceID: AudioDeviceID? = nil) {
        self.ringBuffer = ringBuffer
        self.targetSampleRate = sampleRate
        self.targetDeviceID = targetDeviceID
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

        let input = engine.inputNode

        // Select the requested device BEFORE reading the input format, so the
        // format (and therefore the converter) reflects the chosen device. A
        // nil target leaves the engine on the system default input.
        if let targetDeviceID, let au = input.audioUnit {
            var dev = targetDeviceID
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw CaptureError.engineStartFailed(
                    "could not select input device \(targetDeviceID): OSStatus \(status)")
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

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            removeTap()
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() {
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
