import Testing
import Foundation
@testable import BandwatchCore

// Helpers for reasoning about the smoother's math in the linear power
// domain, which is where the actual smoothing happens (see LevelSmoother's
// doc comment for why).
private func dbToPower(_ dbfs: Double) -> Double {
    pow(10.0, dbfs / 10.0)
}

private func powerToDb(_ power: Double) -> Double {
    10.0 * log10(power)
}

// MARK: - Step response (attack)

/// The defining property of a first-order exponential smoother: after
/// exactly one time constant's worth of samples, the output has closed
/// ~63.2% (1 - 1/e) of the gap to a step input. Picking `hopInterval =
/// timeConstant / n` makes this exact (mod floating-point error): alpha = 1 -
/// exp(-1/n), so (1-alpha)^n = exp(-1) exactly. This is a rising step (target
/// above start), so it exercises the ATTACK alpha, which is the weighting's
/// own time constant. Tested at both Fast and Slow to prove the relationship
/// generalises, not just a coincidence of one value.
@Test func testStepResponseFastReaches63PercentAfterOneTimeConstant() {
    let n = 1000
    let hop = TimeWeighting.fast.timeConstant / Double(n)
    let smoother = LevelSmoother(weighting: .fast, hopInterval: hop)

    let start = -60.0
    let target = -20.0
    _ = smoother.smooth(start) // initialises running power to `start` exactly

    var output = 0.0
    for _ in 0..<n { output = smoother.smooth(target) }

    let expectedPower = dbToPower(target) - (dbToPower(target) - dbToPower(start)) * exp(-1.0)
    let expectedDB = powerToDb(expectedPower)
    #expect(abs(output - expectedDB) < 1e-4)
}

@Test func testStepResponseSlowReaches63PercentAfterOneTimeConstant() {
    let n = 1000
    let hop = TimeWeighting.slow.timeConstant / Double(n)
    let smoother = LevelSmoother(weighting: .slow, hopInterval: hop)

    let start = -60.0
    let target = -20.0
    _ = smoother.smooth(start)

    var output = 0.0
    for _ in 0..<n { output = smoother.smooth(target) }

    let expectedPower = dbToPower(target) - (dbToPower(target) - dbToPower(start)) * exp(-1.0)
    let expectedDB = powerToDb(expectedPower)
    #expect(abs(output - expectedDB) < 1e-4)
}

// MARK: - Steady state

@Test func testConstantInputConvergesToThatSameValue() {
    let smoother = LevelSmoother(weighting: .fast, hopInterval: 0.01)
    _ = smoother.smooth(-70.0) // start far away

    var output = 0.0
    // 50 time constants' worth of samples is comfortably past convergence.
    for _ in 0..<(50 * Int(TimeWeighting.fast.timeConstant / 0.01)) {
        output = smoother.smooth(-30.0)
    }
    #expect(abs(output - (-30.0)) < 1e-6)
}

// MARK: - Fast vs Slow attack

/// Proves the weighting setting still does something: from a settled low
/// level, a rising step (attack) climbs more gradually on Slow than on Fast,
/// because attack uses the selected weighting's own time constant.
@Test func testFastConvergesFasterThanSlowGivenSameStep() {
    let hop = 2048.0 / 44100.0 // real hop interval used by MonitoringSession
    let fast = LevelSmoother(weighting: .fast, hopInterval: hop)
    let slow = LevelSmoother(weighting: .slow, hopInterval: hop)

    let start = -60.0
    let target = -20.0
    _ = fast.smooth(start)
    _ = slow.smooth(start)

    var fastOut = 0.0
    var slowOut = 0.0
    for _ in 0..<5 {
        fastOut = fast.smooth(target)
        slowOut = slow.smooth(target)
    }

    #expect(abs(target - fastOut) < abs(target - slowOut))
}

// MARK: - First sample initialises, does not ramp

@Test func testFirstSampleInitialisesRatherThanRamping() {
    let smoother = LevelSmoother(weighting: .fast, hopInterval: 0.01)
    let output = smoother.smooth(-35.0)
    // Not "something between -35 and 0/-120" -- exactly -35, modulo the
    // floating round-trip through pow/log10.
    #expect(abs(output - (-35.0)) < 1e-9)
}

// MARK: - Variance reduction (the actual requirement this exists to fix)

/// Approximates the observed 12-15 dB frame-to-frame thrash on real
/// microphone audio. The whole point of this component is that the smoothed
/// output's peak-to-peak spread is substantially smaller than the raw
/// input's -- this is the test that pins the real-world requirement.
@Test func testSmoothingReducesVarianceOnAlternatingInput() {
    let hop = 2048.0 / 44100.0
    let smoother = LevelSmoother(weighting: .fast, hopInterval: hop)

    let high = -45.0
    let low = -60.0
    var outputs: [Double] = []
    for i in 0..<200 {
        let input = (i % 2 == 0) ? high : low
        outputs.append(smoother.smooth(input))
    }

    // Skip the initial transient; look at the steady-state limit cycle.
    let steadyState = outputs.suffix(100)
    let smoothedSpread = steadyState.max()! - steadyState.min()!
    let rawSpread = high - low

    #expect(smoothedSpread < rawSpread * 0.5)
}

// MARK: - Silence floor

@Test func testFloorInputConvergesToFloor() {
    let smoother = LevelSmoother(weighting: .fast, hopInterval: 0.01)
    _ = smoother.smooth(-20.0) // start well above the floor

    var output = 0.0
    for _ in 0..<500 {
        output = smoother.smooth(BandLevelMeter.silenceFloorDBFS)
        #expect(output.isFinite)
        #expect(output >= BandLevelMeter.silenceFloorDBFS)
    }
    #expect(abs(output - BandLevelMeter.silenceFloorDBFS) < 1e-3)
}

@Test func testFloorInputNeverProducesBelowFloorOutput() {
    let smoother = LevelSmoother(weighting: .slow, hopInterval: 0.01)
    for _ in 0..<10 {
        let output = smoother.smooth(BandLevelMeter.silenceFloorDBFS)
        #expect(output.isFinite)
        #expect(output >= BandLevelMeter.silenceFloorDBFS)
    }
}

// MARK: - reset()

@Test func testResetReturnsToUninitialisedState() {
    let smoother = LevelSmoother(weighting: .fast, hopInterval: 0.01)
    _ = smoother.smooth(-70.0)
    _ = smoother.smooth(-70.0)
    _ = smoother.smooth(-70.0) // converged near -70

    smoother.reset()

    // If reset() had NOT cleared the running value, this first post-reset
    // sample would be pulled toward -70 rather than landing exactly on -10.
    let output = smoother.smooth(-10.0)
    #expect(abs(output - (-10.0)) < 1e-9)
}

// MARK: - Changing weighting

@Test func testChangingWeightingTakesEffectWithoutResettingRunningValue() {
    let smoother = LevelSmoother(weighting: .fast, hopInterval: 0.01)
    let runningStart = -40.0
    _ = smoother.smooth(runningStart) // initialises running power to -40 exactly

    smoother.weighting = .slow

    let nextInput = -10.0 // rises above runningStart -- exercises the ATTACK alpha
    let output = smoother.smooth(nextInput)

    // If the running value had been discarded on weighting change, this
    // first post-change sample would initialise directly and equal
    // `nextInput` exactly. Instead it must be a blend using the NEW (slow)
    // attack alpha, starting from the OLD running value.
    #expect(abs(output - nextInput) > 1.0)

    let hop = 0.01
    let alphaSlow = 1 - exp(-hop / TimeWeighting.slow.timeConstant)
    let expectedPower = dbToPower(runningStart) + alphaSlow * (dbToPower(nextInput) - dbToPower(runningStart))
    let expectedDB = powerToDb(expectedPower)
    #expect(abs(output - expectedDB) < 1e-6)
}

// MARK: - TimeWeighting

@Test func testTimeWeightingConstants() {
    #expect(TimeWeighting.fast.timeConstant == 0.125)
    #expect(TimeWeighting.slow.timeConstant == 1.0)
    #expect(TimeWeighting.fast.displayName == "Fast")
    #expect(TimeWeighting.slow.displayName == "Slow")
}

// MARK: - Release rate (decay)

/// The property that made a shared symmetric time constant unsuitable for
/// event detection at Slow: exponential power-domain averaging decays at a
/// fixed rate of 10*log10(e) ≈ 4.34 dB per time constant. Feed a high level
/// until settled, then switch to the silence floor and check the drop after
/// exactly one RELEASE time constant's worth of samples -- release is now
/// always LevelSmoother.releaseTimeConstant (0.125 s / "Fast"), regardless of
/// weighting, which is what this test pins.
@Test func testDecayRateIsApproximately4Point34DecibelsPerReleaseTimeConstant() {
    let n = 1000
    let timeConstant = LevelSmoother.releaseTimeConstant
    let hop = timeConstant / Double(n)
    let smoother = LevelSmoother(weighting: .fast, hopInterval: hop)

    let high = -20.0
    // Settle fully onto `high` first (many time constants of runway).
    var settled = 0.0
    for _ in 0..<(20 * n) { settled = smoother.smooth(high) }
    #expect(abs(settled - high) < 1e-6)

    // Now drop to the silence floor and measure the level after exactly one
    // release time constant's worth of samples.
    var afterOneTau = 0.0
    for _ in 0..<n { afterOneTau = smoother.smooth(BandLevelMeter.silenceFloorDBFS) }

    let decibelDrop = settled - afterOneTau
    // Empirically ~4.34 dB (10*log10(e)); allow half a dB of tolerance.
    #expect(abs(decibelDrop - 4.34) < 0.5)
}

// MARK: - Asymmetric attack/release (the point of this change)

/// Regression test for the reported bug: Slow's release must be exactly as
/// fast as Fast's, because release is pinned at
/// `LevelSmoother.releaseTimeConstant` regardless of `weighting`. Settle both
/// smoothers at a high level, then feed the silence floor and confirm both
/// fall at the same rate (~4.34 dB in one release time constant's worth of
/// samples, i.e. ~4.34 dB / 0.125 s).
@Test func testReleaseRateIsTheSameForFastAndSlow() {
    let releaseTau = LevelSmoother.releaseTimeConstant // 0.125
    let n = 1000
    let hop = releaseTau / Double(n)

    let fast = LevelSmoother(weighting: .fast, hopInterval: hop)
    let slow = LevelSmoother(weighting: .slow, hopInterval: hop)

    let high = -20.0
    var fastSettled = 0.0
    var slowSettled = 0.0
    for _ in 0..<(20 * n) {
        fastSettled = fast.smooth(high)
        slowSettled = slow.smooth(high)
    }
    #expect(abs(fastSettled - high) < 1e-6)
    #expect(abs(slowSettled - high) < 1e-6)

    var fastAfter = 0.0
    var slowAfter = 0.0
    for _ in 0..<n {
        fastAfter = fast.smooth(BandLevelMeter.silenceFloorDBFS)
        slowAfter = slow.smooth(BandLevelMeter.silenceFloorDBFS)
    }

    let fastDrop = fastSettled - fastAfter
    let slowDrop = slowSettled - slowAfter

    // Both should show the same ~4.34 dB drop per release time constant.
    #expect(abs(fastDrop - 4.34) < 0.5)
    #expect(abs(slowDrop - 4.34) < 0.5)
    // And critically, they must match each other, not just each be near 4.34.
    #expect(abs(fastDrop - slowDrop) < 0.1)
}

/// Proves the weighting setting still does something on attack: from a
/// settled low level, feed a high level and confirm Slow rises more
/// gradually than Fast -- the asymmetry only pins release, not attack.
@Test func testAttackRateDiffersBetweenFastAndSlow() {
    let hop = 2048.0 / 44100.0
    let fast = LevelSmoother(weighting: .fast, hopInterval: hop)
    let slow = LevelSmoother(weighting: .slow, hopInterval: hop)

    let low = -60.0
    let high = -20.0
    _ = fast.smooth(low)
    _ = slow.smooth(low)

    var fastOut = 0.0
    var slowOut = 0.0
    for _ in 0..<5 {
        fastOut = fast.smooth(high)
        slowOut = slow.smooth(high)
    }

    // Fast must have climbed closer to `high` than Slow has, in the same
    // number of samples.
    #expect(abs(high - fastOut) < abs(high - slowOut))
}

/// The property that stops a single continuous noise from fragmenting into
/// several detector events: a brief mid-noise dip (one or two frames at a
/// much lower level, e.g. a gap in an intermittent drone) must not drag the
/// smoothed level down much, because the dip itself is a release (power
/// falls), and release is fast (0.125 s) -- but the RETURN to loud right
/// after is an attack, which on Slow climbs back gradually starting from
/// wherever the brief dip left the running value. The net dip in the
/// reported level stays small, comfortably inside the detector's 6 dB
/// hysteresis, so a single brief gap does not read as "level dropped below
/// threshold."
@Test func testBriefMidNoiseDipDoesNotDragLevelDownMuch() {
    let hop = 2048.0 / 44100.0 // real hop interval used by MonitoringSession
    let smoother = LevelSmoother(weighting: .slow, hopInterval: hop)

    let loud = -20.0
    let dip = -50.0

    // Settle at loud.
    var settled = 0.0
    for _ in 0..<200 { settled = smoother.smooth(loud) }
    #expect(abs(settled - loud) < 1e-6)

    // One brief dip frame, then straight back to loud.
    let duringDip = smoother.smooth(dip)
    let afterReturn = smoother.smooth(loud)

    let dipDepth = settled - min(duringDip, afterReturn)
    // Comfortably inside the detector's 6 dB hysteresis.
    #expect(dipDepth < 3.0)
}

/// A genuine end-of-noise must still release promptly even on Slow: settle
/// at a loud level, then feed the silence floor continuously, and confirm
/// the smoothed level falls by at least 25 dB within one second (12.5 hops
/// worth of the fixed 0.125 s release time constant, several time constants
/// of runway). This is exactly what a shared 1 s symmetric release failed to
/// do -- it took ~7 seconds for a comparable drop.
@Test func testGenuineEndOfNoiseReleasesPromptlyOnSlow() {
    let hop = 2048.0 / 44100.0 // real hop interval used by MonitoringSession
    let smoother = LevelSmoother(weighting: .slow, hopInterval: hop)

    let loud = -20.0
    var settled = 0.0
    for _ in 0..<200 { settled = smoother.smooth(loud) }
    #expect(abs(settled - loud) < 1e-6)

    var output = 0.0
    var elapsed = 0.0
    while elapsed < 1.0 {
        output = smoother.smooth(BandLevelMeter.silenceFloorDBFS)
        elapsed += hop
    }

    let drop = settled - output
    #expect(drop >= 25.0)
}
