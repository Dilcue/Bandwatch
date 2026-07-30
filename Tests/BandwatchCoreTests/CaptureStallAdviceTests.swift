import Testing
import CoreAudio
@testable import BandwatchCore

@Test func testStallMessageNamesMultiOutputWhenDefaultOutputIsAggregate() {
    let m = CaptureStallAdvice.message(defaultOutputIsAggregate: true)
    #expect(m.contains("Multi-Output"))
    #expect(m.contains("Output"))                       // points at system output
    #expect(m.lowercased().contains("microphone") == false)   // must NOT misdirect
}

@Test func testStallMessageGivesInputAdviceWhenOutputIsOrdinary() {
    let m = CaptureStallAdvice.message(defaultOutputIsAggregate: false)
    #expect(m.lowercased().contains("microphone"))
    #expect(m.contains("Multi-Output") == false)
}

@Test func testAggregateTransportClassifier() {
    // A Multi-Output Device and an Aggregate Device both report this transport
    // type; ordinary devices do not.
    #expect(CoreAudioInputDevices.isAggregateTransport(kAudioDeviceTransportTypeAggregate) == true)
    #expect(CoreAudioInputDevices.isAggregateTransport(kAudioDeviceTransportTypeUSB) == false)
    #expect(CoreAudioInputDevices.isAggregateTransport(kAudioDeviceTransportTypeBuiltIn) == false)
}

@Test func testDefaultOutputIsAggregateQueryRunsWithoutTrapping() {
    // Smoke test of the real HAL query: on the test machine the default output is
    // an ordinary device, so this is typically false — we only assert it returns
    // a value rather than trapping or hanging.
    _ = CoreAudioInputDevices.defaultOutputIsAggregate()
}
