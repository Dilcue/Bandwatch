import Testing
import Foundation
@testable import BandwatchCore

@Test func testEngineConstructsWithoutStarting() {
    let buf = RingBuffer(capacity: 44100)
    let engine = AudioCaptureEngine(ringBuffer: buf, sampleRate: 44100)
    #expect(engine.isRunning == false)
}

@Test func testStopOnNonRunningEngineIsSafe() {
    let buf = RingBuffer(capacity: 44100)
    let engine = AudioCaptureEngine(ringBuffer: buf, sampleRate: 44100)
    engine.stop()   // must not crash
    #expect(engine.isRunning == false)
}

// NOTE: The path where `AVAudioConverter(from:to:)` returns nil because a
// genuinely unsupported input/target format pair is presented (conversion is
// needed but unavailable) cannot be triggered in this test suite — it
// requires real hardware presenting an exotic input format, which cannot be
// forced under Swift Testing without mocking AVAudioEngine's input node
// (out of scope here). That branch in `AudioCaptureEngine.start()` remains
// unverified by automated tests and must be exercised via manual
// verification on real hardware.
