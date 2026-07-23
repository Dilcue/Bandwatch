import Testing
import Foundation
@testable import BandwatchCore

@Test func testStartsNearZero() {
    let c = MonotonicClock()
    #expect(c.now() < 0.1)
}

@Test func testAdvances() {
    let c = MonotonicClock()
    let a = c.now()
    Thread.sleep(forTimeInterval: 0.05)
    let b = c.now()
    #expect(b > a)
    #expect(b - a >= 0.04)
}

@Test func testNeverDecreases() {
    let c = MonotonicClock()
    var last = c.now()
    for _ in 0..<200 {
        let t = c.now()
        #expect(t >= last)
        last = t
    }
}

@Test func testResetRestartsFromZero() {
    var c = MonotonicClock()
    Thread.sleep(forTimeInterval: 0.05)
    #expect(c.now() > 0.04)
    c.reset()
    #expect(c.now() < 0.01)
}
