import Testing
import Foundation
import AVFoundation
@testable import BandwatchCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwflac-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func tone(_ n: Int, freq: Double = 55, sr: Double = 44100, amp: Float = 0.5) -> [Float] {
    (0..<n).map { amp * Float(sin(2.0 * .pi * freq * Double($0) / sr)) }
}

@Test func testWritesAReadableFileAfterClose() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("a.flac")
    let w = try FLACWriter(url: url, sampleRate: 44100)
    try w.append(tone(44100))
    w.close()

    #expect(FileManager.default.fileExists(atPath: url.path))
    // Readable only after close — this is the verified constraint.
    let f = try AVAudioFile(forReading: url)
    #expect(f.length == 44100)
    #expect(f.fileFormat.channelCount == 1)
    #expect(f.fileFormat.sampleRate == 44100)
}

@Test func testCreatesParentDirectories() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("x/y/z.flac")
    let w = try FLACWriter(url: url, sampleRate: 44100)
    try w.append(tone(1000))
    w.close()
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func testMultipleAppendsAccumulate() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("b.flac")
    let w = try FLACWriter(url: url, sampleRate: 44100)
    for _ in 0..<10 { try w.append(tone(4410)) }
    #expect(w.framesWritten == 44100)
    w.close()
    let f = try AVAudioFile(forReading: url)
    #expect(f.length == 44100)
}

// MARK: - isOutOfSpace classification
//
// Disk-full must be distinguishable from other init/append failures so a
// future coordinator can log the correct GapReason (.diskFull vs
// .writeFailure) instead of misattributing lost coverage. Filling a real
// disk in a test is impractical, so these construct the NSError shapes
// directly and exercise the classification helper in isolation.

@Test func testIsOutOfSpaceDetectsCocoaOutOfSpace() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    #expect(FLACWriter.isOutOfSpace(error))
}

@Test func testIsOutOfSpaceDetectsPosixENOSPC() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    #expect(FLACWriter.isOutOfSpace(error))
}

@Test func testIsOutOfSpaceDetectsWrappedUnderlyingPosixENOSPC() {
    // Core Audio commonly wraps the POSIX error one level deep.
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let wrapper = NSError(
        domain: "com.apple.coreaudio.avfaudio",
        code: -1,
        userInfo: [NSUnderlyingErrorKey: posix])
    #expect(FLACWriter.isOutOfSpace(wrapper))
}

@Test func testIsOutOfSpaceRejectsUnrelatedError() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    #expect(!FLACWriter.isOutOfSpace(error))
}

@Test func testAudioSurvivesRoundTrip() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("c.flac")
    let w = try FLACWriter(url: url, sampleRate: 44100)
    try w.append(tone(8192, amp: 0.5))
    w.close()

    let f = try AVAudioFile(forReading: url)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8192)!
    try f.read(into: buf)
    var peak: Float = 0
    let p = buf.floatChannelData![0]
    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(p[i])) }
    // FLAC is lossless; a 0.5 peak must come back as 0.5.
    #expect(abs(peak - 0.5) < 0.01)
}

@Test func testAppendAfterCloseThrows() throws {
    let dir = tempDir()
    let w = try FLACWriter(url: dir.appendingPathComponent("d.flac"), sampleRate: 44100)
    try w.append(tone(100))
    w.close()
    #expect(throws: RecordingError.self) { try w.append(tone(100)) }
}

@Test func testCloseIsIdempotent() throws {
    let dir = tempDir()
    let w = try FLACWriter(url: dir.appendingPathComponent("e.flac"), sampleRate: 44100)
    try w.append(tone(100))
    w.close()
    w.close()   // must not crash
}

@Test func testEmptyAppendIsSafe() throws {
    let dir = tempDir()
    let w = try FLACWriter(url: dir.appendingPathComponent("f.flac"), sampleRate: 44100)
    try w.append([])
    #expect(w.framesWritten == 0)
    w.close()
}

@Test func testEmptyAppendAfterCloseThrows() throws {
    // append([]) must not silently succeed just because the array is empty —
    // open-state is checked before the empty-array short-circuit, so misuse
    // after close() is reported the same way regardless of array size.
    let dir = tempDir()
    let w = try FLACWriter(url: dir.appendingPathComponent("f2.flac"), sampleRate: 44100)
    try w.append(tone(100))
    w.close()
    #expect(throws: RecordingError.notOpen) { try w.append([]) }
}

@Test func testCloseMidStreamProducesValidFileOfFramesSoFar() throws {
    // Stand-in for the untested crash-safety property: if a future append
    // throws mid-write, `self.file` is left intact (the catch in append()
    // rethrows without clearing it), so a subsequent close() still finalises
    // whatever was durably written. That exact failure path can't be forced
    // in a test without actually exhausting disk space, so instead we verify
    // the adjacent, testable guarantee — closing after an arbitrary sequence
    // of successful appends always yields a valid, readable file containing
    // exactly the frames appended so far. The true mid-write-failure path
    // remains unverified by this suite.
    let dir = tempDir()
    let url = dir.appendingPathComponent("h.flac")
    let w = try FLACWriter(url: url, sampleRate: 44100)
    try w.append(tone(4410))
    try w.append(tone(4410))
    try w.append(tone(4410))
    // Stop at an arbitrary point mid-stream (not a round total like 44100),
    // as if a later append had failed and this were the last durable data.
    w.close()

    #expect(w.framesWritten == 13230)
    let f = try AVAudioFile(forReading: url)
    #expect(f.length == 13230)
}

// MARK: - Overwrite guard (additional requirement beyond the brief)
//
// AVAudioFile(forWriting:) silently truncates an existing file. Bandwatch
// records evidence; silently destroying a previous recording is the one
// failure this product cannot have. init must throw instead of truncating,
// and the original file's contents must survive the attempt.

@Test func testInitThrowsIfFileAlreadyExists() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("g.flac")

    let w1 = try FLACWriter(url: url, sampleRate: 44100)
    try w1.append(tone(44100))
    w1.close()

    let originalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int

    #expect(throws: RecordingError.self) {
        _ = try FLACWriter(url: url, sampleRate: 44100)
    }

    // Original file must be untouched — not truncated, not replaced.
    let survivingSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(survivingSize == originalSize)

    let f = try AVAudioFile(forReading: url)
    #expect(f.length == 44100)
}
