import Testing
import Foundation
@testable import BandwatchCore

@Test func testSameDayWindowPredicate() {
    let s = MonitoringSchedule(isEnabled: true, startMinuteOfDay: 6*60, endMinuteOfDay: 18*60)
    #expect(s.isWithin(minuteOfDay: 6*60))        // inclusive start
    #expect(s.isWithin(minuteOfDay: 12*60))
    #expect(!s.isWithin(minuteOfDay: 18*60))      // exclusive end
    #expect(!s.isWithin(minuteOfDay: 5*60+59))
    #expect(!s.isWithin(minuteOfDay: 20*60))
}

@Test func testOvernightWindowPredicate() {
    let s = MonitoringSchedule(isEnabled: true, startMinuteOfDay: 22*60, endMinuteOfDay: 7*60)
    #expect(s.isWithin(minuteOfDay: 23*60))       // after start, before midnight
    #expect(s.isWithin(minuteOfDay: 2*60))        // after midnight, before end
    #expect(s.isWithin(minuteOfDay: 22*60))       // inclusive start
    #expect(!s.isWithin(minuteOfDay: 7*60))       // exclusive end
    #expect(!s.isWithin(minuteOfDay: 12*60))      // the daytime gap
}

@Test func testDegenerateWindowIsNeverActive() {
    let s = MonitoringSchedule(isEnabled: true, startMinuteOfDay: 600, endMinuteOfDay: 600)
    #expect(!s.isWithin(minuteOfDay: 600))
    #expect(!s.isWithin(minuteOfDay: 0))
}

@Test func testPersistenceRoundTripAndDefault() {
    let suiteName = "bw-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suiteName)!
    defer { d.removePersistentDomain(forName: suiteName) }
    // Fresh: disabled, 6-18.
    let def = MonitoringSchedule.load(from: d)
    #expect(def == MonitoringSchedule(isEnabled: false, startMinuteOfDay: 360, endMinuteOfDay: 1080))
    MonitoringSchedule(isEnabled: true, startMinuteOfDay: 22*60, endMinuteOfDay: 7*60).save(to: d)
    #expect(MonitoringSchedule.load(from: d) == MonitoringSchedule(isEnabled: true, startMinuteOfDay: 1320, endMinuteOfDay: 420))
}
