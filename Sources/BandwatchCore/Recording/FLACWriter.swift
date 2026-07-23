import AVFoundation
import Foundation

public enum RecordingError: Error, Equatable {
    case couldNotCreateFile(String)
    case writeFailed(String)
    case notOpen
    case fileExists(String)
    case diskFull(String)
}

/// Writes one band-filtered FLAC file.
///
/// Not thread-safe and not Sendable by design — it is used only from inside
/// `RecordingCoordinator`, which provides isolation.
///
/// Two verified constraints:
/// - The file is NOT readable until `close()` releases the underlying
///   `AVAudioFile`. Opening a still-open file fails with ExtAudioFileOpenURL
///   error 1718449215.
/// - `AVAudioFile.length` lags during writing, so frames written are counted
///   here rather than read back from the file.
///
/// `init` refuses to overwrite an existing file. `AVAudioFile(forWriting:)`
/// silently truncates whatever is already at `url`, and this app records
/// evidence: filename uniqueness (millisecond + UTC offset) makes collisions
/// unlikely, but a clock adjustment, a restart, or a future path change could
/// still produce one. Silently destroying a previous recording is the one
/// failure this product cannot have, so a collision must fail loudly instead.
public final class FLACWriter {
    public let url: URL
    public private(set) var framesWritten: Int = 0

    private var file: AVAudioFile?
    private let format: AVAudioFormat

    public init(url: URL, sampleRate: Double) throws {
        self.url = url

        // TOCTOU: fileExists and AVAudioFile(forWriting:) below are not atomic
        // together. Known and accepted under the single-writer design.
        if FileManager.default.fileExists(atPath: url.path) {
            throw RecordingError.fileExists(url.path)
        }

        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            if Self.isOutOfSpace(error) {
                throw RecordingError.diskFull(
                    "could not create \(dir.path): \(error.localizedDescription)")
            }
            throw RecordingError.couldNotCreateFile(
                "could not create \(dir.path): \(error.localizedDescription)")
        }

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecordingError.couldNotCreateFile("bad format at \(sampleRate) Hz")
        }
        self.format = fmt

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            if Self.isOutOfSpace(error) {
                throw RecordingError.diskFull(
                    "\(url.lastPathComponent): \(error.localizedDescription)")
            }
            throw RecordingError.couldNotCreateFile(
                "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func append(_ samples: [Float]) throws {
        guard let file else { throw RecordingError.notOpen }
        guard !samples.isEmpty else { return }

        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RecordingError.writeFailed("could not allocate buffer")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        do {
            try file.write(from: buf)
        } catch {
            if Self.isOutOfSpace(error) {
                throw RecordingError.diskFull(
                    "\(url.lastPathComponent): \(error.localizedDescription)")
            }
            throw RecordingError.writeFailed(
                "\(url.lastPathComponent): \(error.localizedDescription)")
        }
        framesWritten += samples.count
    }

    /// Releases the file so it becomes readable. Idempotent.
    public func close() {
        file = nil
    }

    /// True if `error` represents an out-of-space condition, checked both
    /// directly and one level into `NSUnderlyingErrorKey` (Core Audio
    /// commonly wraps the POSIX error there).
    ///
    /// `internal` rather than `private` so it can be unit-tested directly
    /// with constructed `NSError` values — filling a real disk in tests is
    /// impractical.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if Self.isOutOfSpaceCode(nsError) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           Self.isOutOfSpaceCode(underlying) {
            return true
        }
        return false
    }

    private static func isOutOfSpaceCode(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileWriteOutOfSpaceError
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOSPC)
        default:
            return false
        }
    }
}
