import Testing
import Foundation
@testable import BandwatchCore

@Test func testDayWithEventsIsEvents() {
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 4,
                                   monitoredSecondsThatDay: 3600)
    #expect(s == .events(4))
}

@Test func testMonitoredButZeroEventsIsQuiet() {
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 0,
                                   monitoredSecondsThatDay: 80000)   // well above the 1h floor
    #expect(s == .quiet)
}

@Test func testBarelyMonitoredZeroEventsIsNotMonitored() {
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 0,
                                   monitoredSecondsThatDay: 1000)    // below the 1h floor
    #expect(s == .notMonitored)
}

@Test func testEventsWinEvenWithPartialCoverage() {
    // An event is proof something was heard, regardless of how little was covered.
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 1,
                                   monitoredSecondsThatDay: 500)
    #expect(s == .events(1))
}

@Test func testExactlyOneHourIsQuiet() {
    // The floor is inclusive: exactly 1h of coverage with no events is quiet.
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 0,
                                   monitoredSecondsThatDay: 3600)
    #expect(s == .quiet)
}

@Test func testJustUnderOneHourIsNotMonitored() {
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 0,
                                   monitoredSecondsThatDay: 3599)
    #expect(s == .notMonitored)
}

@Test func testNightOnlyMonitoredQuietDayIsQuiet() {
    // A typical night-only monitoring session (e.g. 10pm-7am ~ 6-9h) covers well
    // under half a calendar day. The old 50%-of-day threshold wrongly classified
    // this as "not monitored"; the new absolute 1h floor correctly calls it quiet.
    let s = DayClassifier.classify(day: DateComponents(), eventCount: 0,
                                   monitoredSecondsThatDay: 21600)   // 6 hours
    #expect(s == .quiet)
}
