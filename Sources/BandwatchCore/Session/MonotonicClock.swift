import Foundation

/// Monotonic time source for detection.
///
/// Detection must never be driven by wall-clock time. A backwards NTP
/// correction would make `time - lastAboveRelease` negative so an event could
/// never release; a forward step would instantly trip `maximumDuration`. Since
/// this app writes durations into permanent evidence, detection timing has to
/// be immune to clock adjustments.
///
/// Wall-clock time is still used — but only for values written to disk: file
/// names, segment boundaries, and event row timestamps.
public struct MonotonicClock: Sendable {
    private var start: ContinuousClock.Instant

    public init() {
        self.start = ContinuousClock.now
    }

    public func now() -> TimeInterval {
        let d = ContinuousClock.now - start
        return TimeInterval(d.components.seconds)
            + TimeInterval(d.components.attoseconds) / 1e18
    }

    public mutating func reset() {
        start = ContinuousClock.now
    }
}
