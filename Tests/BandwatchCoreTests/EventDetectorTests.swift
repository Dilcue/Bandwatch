import Testing
import Foundation
@testable import BandwatchCore

private func makeConfig(
    trigger: Double = -30,
    releaseOffset: Double = 6,
    minDuration: TimeInterval = 2,
    releaseTime: TimeInterval = 5,
    maxDuration: TimeInterval = 300
) -> DetectorConfig {
    DetectorConfig(
        triggerDBFS: trigger,
        releaseOffsetDB: releaseOffset,
        minimumDuration: minDuration,
        releaseTime: releaseTime,
        maximumDuration: maxDuration
    )
}

/// Feeds a level held constant for `seconds`, one sample every 0.1s.
/// Returns any events emitted, and the time cursor after feeding.
@discardableResult
private func feed(
    _ d: EventDetector,
    level: Double,
    seconds: TimeInterval,
    from start: TimeInterval,
    into events: inout [DetectedEvent]
) -> TimeInterval {
    var t = start
    let step = 0.1
    let end = start + seconds
    while t < end {
        if let e = d.process(level: level, at: t) { events.append(e) }
        t += step
    }
    return t
}

@Test func testStartsIdle() {
    let d = EventDetector(config: makeConfig())
    #expect(d.state == .idle)
}

@Test func testQuietLevelNeverTriggers() {
    let d = EventDetector(config: makeConfig())
    var events: [DetectedEvent] = []
    feed(d, level: -60, seconds: 30, from: 0, into: &events)
    #expect(events.isEmpty)
    #expect(d.state == .idle)
}

@Test func testLoudLevelEntersCandidateThenRecording() {
    let d = EventDetector(config: makeConfig(minDuration: 2))
    var events: [DetectedEvent] = []
    _ = d.process(level: -20, at: 0)
    #expect(d.state == .candidate)
    feed(d, level: -20, seconds: 3, from: 0.1, into: &events)
    #expect(d.state == .recording)
}

@Test func testTransientShorterThanMinimumDurationIsDiscarded() {
    // A door slam: loud for 1s, min duration is 2s.
    let d = EventDetector(config: makeConfig(minDuration: 2))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 1.0, from: 0, into: &events)
    t = feed(d, level: -60, seconds: 10, from: t, into: &events)
    #expect(events.isEmpty)
    #expect(d.state == .idle)
}

@Test func testSustainedNoiseEmitsOneEventOnRelease() {
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 10, from: 0, into: &events)
    #expect(events.isEmpty)  // still recording
    t = feed(d, level: -60, seconds: 6, from: t, into: &events)
    #expect(events.count == 1)
    #expect(d.state == .idle)
}

@Test func testHysteresisPreventsMachineGunning() {
    // Level oscillates between trigger and just under it (but above release).
    // Trigger -30, release offset 6 -> release -36. Oscillate -28 / -33.
    let d = EventDetector(config: makeConfig(trigger: -30, releaseOffset: 6, minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t: TimeInterval = 0
    for _ in 0..<50 {
        t = feed(d, level: -28, seconds: 0.3, from: t, into: &events)
        t = feed(d, level: -33, seconds: 0.3, from: t, into: &events)
    }
    // -33 is above the -36 release threshold, so this is ONE event, not fifty.
    #expect(events.isEmpty)
    #expect(d.state == .recording)
    let final = d.finish(at: t)
    #expect(final != nil)
}

@Test func testShortPauseDoesNotSplitEvent() {
    // Release time 5s; pause for 2s mid-event.
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 5, from: 0, into: &events)
    t = feed(d, level: -60, seconds: 2, from: t, into: &events)   // brief pause
    t = feed(d, level: -20, seconds: 5, from: t, into: &events)   // resumes
    #expect(events.isEmpty)                                        // not split
    t = feed(d, level: -60, seconds: 6, from: t, into: &events)   // real release
    #expect(events.count == 1)
}

@Test func testPauseLongerThanReleaseTimeSplitsEvents() {
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 5, from: 0, into: &events)
    t = feed(d, level: -60, seconds: 7, from: t, into: &events)   // exceeds release
    #expect(events.count == 1)
    t = feed(d, level: -20, seconds: 5, from: t, into: &events)
    t = feed(d, level: -60, seconds: 7, from: t, into: &events)
    #expect(events.count == 2)
}

@Test func testMaximumDurationSplitsContinuousNoise() {
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5, maxDuration: 10))
    var events: [DetectedEvent] = []
    // 35 seconds of continuous noise with a 10s cap -> at least 3 splits.
    let t = feed(d, level: -20, seconds: 35, from: 0, into: &events)
    #expect(events.count >= 3)
    #expect(events.allSatisfy { $0.duration <= 10.5 })
    _ = d.finish(at: t)
}

@Test func testLevelExactlyAtThresholdTriggers() {
    let d = EventDetector(config: makeConfig(trigger: -30, minDuration: 2))
    var events: [DetectedEvent] = []
    _ = d.process(level: -30, at: 0)
    #expect(d.state == .candidate)
    feed(d, level: -30, seconds: 3, from: 0.1, into: &events)
    #expect(d.state == .recording)
}

@Test func testLevelJustBelowThresholdDoesNotTrigger() {
    let d = EventDetector(config: makeConfig(trigger: -30))
    _ = d.process(level: -30.01, at: 0)
    #expect(d.state == .idle)
}

@Test func testEventRecordsPeakAndMean() {
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 3, from: 0, into: &events)
    t = feed(d, level: -10, seconds: 3, from: t, into: &events)   // louder peak
    t = feed(d, level: -60, seconds: 6, from: t, into: &events)
    let e = try! #require(events.first)
    #expect(abs(e.peakDBFS - (-10)) < 0.001)
    #expect(e.meanDBFS > -30 && e.meanDBFS < -10)
}

@Test func testMeanExcludesTrailingReleaseSilence() {
    // Regression: the release window feeds quiet samples to the detector while
    // it is still in .recording. Those must not count toward the event's mean.
    let d = EventDetector(config: makeConfig(trigger: -30, minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -20, seconds: 4, from: 0, into: &events)
    t = feed(d, level: -90, seconds: 6, from: t, into: &events)   // long quiet tail
    let e = try! #require(events.first)
    // Mean must reflect the -20 dB noise, not be dragged toward -90.
    #expect(abs(e.meanDBFS - (-20)) < 0.5)
}

@Test func testEventStartTimeIsWhenLevelFirstCrossed() {
    let d = EventDetector(config: makeConfig(minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []
    var t = feed(d, level: -60, seconds: 5, from: 0, into: &events)
    let crossAt = t
    t = feed(d, level: -20, seconds: 5, from: t, into: &events)
    t = feed(d, level: -60, seconds: 6, from: t, into: &events)
    let e = try! #require(events.first)
    // Start time is the crossing, not the moment min-duration was satisfied.
    #expect(abs(e.startTime - crossAt) < 0.2)
}

@Test func testFinishClosesInProgressEvent() {
    let d = EventDetector(config: makeConfig(minDuration: 2))
    var events: [DetectedEvent] = []
    let t = feed(d, level: -20, seconds: 5, from: 0, into: &events)
    #expect(events.isEmpty)
    let e = d.finish(at: t)
    #expect(e != nil)
    #expect(d.state == .idle)
}

@Test func testFinishReturnsNilWhenIdle() {
    let d = EventDetector(config: makeConfig())
    #expect(d.finish(at: 10) == nil)
}

@Test func testFinishDiscardsCandidateBelowMinimumDuration() {
    let d = EventDetector(config: makeConfig(minDuration: 2))
    var events: [DetectedEvent] = []
    let t = feed(d, level: -20, seconds: 0.5, from: 0, into: &events)
    #expect(d.finish(at: t) == nil)
}

@Test func testChangingConfigResetsToIdle() {
    let d = EventDetector(config: makeConfig())
    var events: [DetectedEvent] = []
    feed(d, level: -20, seconds: 5, from: 0, into: &events)
    #expect(d.state == .recording)
    d.config = makeConfig(trigger: -10)
    #expect(d.state == .idle)
}

@Test func testReleaseThresholdIsDerivedFromOffset() {
    let c = makeConfig(trigger: -30, releaseOffset: 6)
    #expect(c.releaseDBFS == -36)
}

// MARK: - Finding 1: maximumDuration split path end-time consistency

@Test func testMaximumDurationSplitUsesLastAboveReleaseNotCapTime() {
    // Trigger -30, release -36, maximumDuration 10.
    // Loud (-20 dBFS) from t=0 through t=9.4, then quiet (-60 dBFS, well
    // below the -36 release floor) from t=9.5 onward. The cap fires at
    // t=10.0 (time - eventStart >= maximumDuration), but the last sample
    // that counted toward the event's statistics was at t=9.4 -- the
    // `accumulate` guard excludes the quiet tail from peak/mean just as it
    // does on the ordinary release path. The emitted duration must agree,
    // i.e. reflect lastAboveRelease (9.4), not the raw cap time (10.0).
    let d = EventDetector(config: makeConfig(trigger: -30, releaseOffset: 6, minDuration: 2, releaseTime: 5, maxDuration: 10))
    var events: [DetectedEvent] = []

    // t = 0.0 ... 9.4 inclusive, loud.
    for i in 0...94 {
        let t = Double(i) * 0.1
        if let e = d.process(level: -20, at: t) { events.append(e) }
    }
    // t = 9.5 ... 9.9, quiet -- below release, excluded from stats and
    // from lastAboveRelease.
    for i in 95...99 {
        let t = Double(i) * 0.1
        if let e = d.process(level: -60, at: t) { events.append(e) }
    }
    // t = 10.0: cap fires (time - eventStart == 10.0 >= maximumDuration).
    if let e = d.process(level: -60, at: 10.0) { events.append(e) }

    let e = try! #require(events.first)
    // Duration must correspond to the last above-release sample (~9.4),
    // not the raw cap time (10.0).
    #expect(abs(e.duration - 9.4) < 0.05)
    #expect(e.duration < 9.45)
    // Consistency: statistics reflect only the loud samples, and duration
    // must not overstate beyond what those statistics were computed over.
    #expect(abs(e.peakDBFS - (-20)) < 0.001)
    #expect(abs(e.meanDBFS - (-20)) < 0.001)
}

@Test func testMaximumDurationSplitsContinuousNoiseStillCapsAtMaximumDuration() {
    // When the level never dips below release, lastAboveRelease == time at
    // every sample, so the fix must not change the emitted duration for
    // continuous noise: it still equals maximumDuration exactly.
    let d = EventDetector(config: makeConfig(trigger: -30, releaseOffset: 6, minDuration: 2, releaseTime: 5, maxDuration: 10))
    var events: [DetectedEvent] = []
    let t = feed(d, level: -20, seconds: 22, from: 0, into: &events)
    #expect(events.count >= 2)
    for e in events {
        #expect(abs(e.duration - 10.0) < 0.15)
    }
    _ = d.finish(at: t)
}

// MARK: - Finding 3: finish() correctly discards a lingering .candidate

@Test func testFinishDiscardsCandidateEvenThoughElapsedTimeWouldQualify() {
    // Pinning test: process() promotes .candidate to .recording the moment
    // time - eventStart >= minimumDuration. So a .candidate still lingering
    // when finish() is called necessarily has LESS than minimumDuration of
    // *observed* above-threshold signal -- emitting it would fabricate
    // duration over a window with no samples. For an evidence tool,
    // fabricating duration is worse than dropping a marginal event. This
    // must NOT be "fixed" to emit an event here.
    let d = EventDetector(config: makeConfig(trigger: -30, minDuration: 2))
    _ = d.process(level: -20, at: 0)
    _ = d.process(level: -20, at: 1.9)
    #expect(d.state == .candidate)
    #expect(d.finish(at: 2.5) == nil)
}

// MARK: - Finding 2: DetectorConfig validation

@Test func testConfigWithAllDefaultsConstructsFine() {
    let c = DetectorConfig(triggerDBFS: -30)
    #expect(c.minimumDuration == 1.5)
    #expect(c.releaseTime == 3.0)
    #expect(c.maximumDuration == 300.0)
    #expect(c.releaseOffsetDB == 6.0)
}

@Test func testConfigWithValidCustomValuesConstructsFine() {
    let c = DetectorConfig(
        triggerDBFS: -25,
        releaseOffsetDB: 3,
        minimumDuration: 0,
        releaseTime: 0,
        maximumDuration: 1
    )
    #expect(c.minimumDuration == 0)
    #expect(c.releaseTime == 0)
    #expect(c.maximumDuration == 1)
}

@Test func testConfigWhereMaximumDurationEqualsMinimumDurationConstructsFine() {
    let c = DetectorConfig(triggerDBFS: -30, minimumDuration: 5, maximumDuration: 5)
    #expect(c.minimumDuration == 5)
    #expect(c.maximumDuration == 5)
}

// MARK: - Finding 4: finish() must use lastAboveRelease for consistency with release and cap paths

@Test func testFinishClosesEventAtLastAboveReleaseNotRawTime() {
    // Regression: finish() closing an in-progress event must report duration
    // that agrees with the event's peak/mean statistics. The event records
    // only samples >= releaseDBFS (line 136 of EventDetector.swift), so
    // duration must end at the last such sample (lastAboveRelease), not the
    // raw finish() time. Overstating event length undermines credibility
    // for an evidence-recording tool.
    //
    // Concrete case: trigger -30, release -36, releaseTime 5.
    // Loud (-20) from t=0 to t=10.0, then quiet (-60, below -36) from t=10.1
    // to t=13.0. finish(at: 13) is called before release timer expires.
    // The last above-release sample is at ~10.0. Duration must report ~10,
    // not 13.0 (a 3-second overstatement).
    let d = EventDetector(config: makeConfig(trigger: -30, releaseOffset: 6, minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []

    // t = 0.0 ... 10.0, loud.
    for i in 0...100 {
        let t = Double(i) * 0.1
        if let e = d.process(level: -20, at: t) { events.append(e) }
    }
    #expect(d.state == .recording)

    // t = 10.1 ... 13.0, quiet (below -36 release threshold).
    for i in 101...130 {
        let t = Double(i) * 0.1
        if let e = d.process(level: -60, at: t) { events.append(e) }
    }

    // finish() at 13.0, before release timer has elapsed (would need 5s below release).
    let e = d.finish(at: 13.0)
    let event = try! #require(e)

    // Duration must correspond to the last above-release sample (~10.0),
    // not the raw finish time (13.0).
    #expect(event.duration < 10.5, "Expected duration ~10, but got \(event.duration)")
    #expect(event.duration > 9.9, "Expected duration ~10, but got \(event.duration)")
    // Consistency check: peak and mean reflect only the loud period.
    #expect(abs(event.peakDBFS - (-20)) < 0.001)
    #expect(abs(event.meanDBFS - (-20)) < 0.001)
}

@Test func testFinishExtendsDurationWhenLoudUntilTheEnd() {
    // Verify the fix does not change behavior when audio remains above
    // release threshold all the way until finish(). In that case,
    // lastAboveRelease == the final sample's time, so duration still
    // extends to the final sample.
    let d = EventDetector(config: makeConfig(trigger: -30, releaseOffset: 6, minDuration: 2, releaseTime: 5))
    var events: [DetectedEvent] = []

    // Continuous loud audio from t=0 to t=8.0.
    let finalTime = feed(d, level: -20, seconds: 8.0, from: 0, into: &events)
    #expect(d.state == .recording)
    #expect(events.isEmpty)

    // finish() at the final sample time.
    let e = d.finish(at: finalTime)
    let event = try! #require(e)

    // Duration must still extend to the final sample (8.0).
    #expect(abs(event.duration - 8.0) < 0.15, "Expected duration ~8.0, but got \(event.duration)")
}
