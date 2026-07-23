import Testing
import Foundation
@testable import BandwatchCore

@Test func testBaselineIsNilBeforeEnoughSamples() {
    let e = BaselineEstimator()
    for _ in 0..<10 { e.add(level: -60) }
    #expect(e.baselineDBFS == nil)
    #expect(e.suggestedThresholdDBFS == nil)
}

@Test func testBaselineAvailableAfterMinimumSamples() {
    let e = BaselineEstimator()
    for _ in 0..<BaselineEstimator.minimumSamples { e.add(level: -60) }
    #expect(e.baselineDBFS != nil)
    #expect(abs(e.baselineDBFS! - (-60)) < 0.001)
}

@Test func testSuggestedThresholdIsBaselinePlusMargin() {
    let e = BaselineEstimator()
    for _ in 0..<BaselineEstimator.minimumSamples { e.add(level: -60) }
    #expect(abs(e.suggestedThresholdDBFS! - (-60 + BaselineEstimator.margin)) < 0.001)
}

@Test func testMedianIgnoresOccasionalLoudEvents() {
    let e = BaselineEstimator()
    // 90% quiet, 10% loud — median must track the quiet room.
    for i in 0..<BaselineEstimator.minimumSamples {
        e.add(level: i % 10 == 0 ? -10 : -60)
    }
    #expect(abs(e.baselineDBFS! - (-60)) < 0.001)
}

@Test func testWindowEvictsOldestSamples() {
    let e = BaselineEstimator(windowSize: BaselineEstimator.minimumSamples)
    for _ in 0..<BaselineEstimator.minimumSamples { e.add(level: -80) }
    #expect(abs(e.baselineDBFS! - (-80)) < 0.001)
    // Fully replace the window with a new level.
    for _ in 0..<BaselineEstimator.minimumSamples { e.add(level: -40) }
    #expect(abs(e.baselineDBFS! - (-40)) < 0.001)
}

@Test func testResetClearsBaseline() {
    let e = BaselineEstimator()
    for _ in 0..<BaselineEstimator.minimumSamples { e.add(level: -60) }
    e.reset()
    #expect(e.baselineDBFS == nil)
}
