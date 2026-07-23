import Foundation

/// Classifies a calendar day for the review calendar heatmap.
///
/// The three states must be visually distinct because they are different
/// evidentiary claims: "there was noise", "it was quiet", and "we were not
/// listening". Collapsing the last two would let a dead microphone masquerade
/// as a quiet day.
public enum DayState: Equatable, Sendable {
    case events(Int)      // monitored (fully or partly) and something was detected
    case quiet            // monitored, nothing detected — a defensible quiet day
    case notMonitored     // below the monitoring floor — too little coverage to claim anything
}

public struct DayClassifier {
    /// A day (a full calendar day, midnight to midnight) with at least this much
    /// monitoring and no events is a defensible "quiet" day. This is an ABSOLUTE
    /// floor, not a fraction of the day: monitoring commonly runs for a stretch
    /// rather than a full 24 hours, so a fraction-of-day threshold would mislabel
    /// a genuinely-monitored quiet period as "not monitored". The floor still
    /// prevents a trivially short span (a few minutes) from claiming a whole day
    /// was quiet. A day with a span but below the floor, and no events, reads
    /// "not monitored" — the safe, under-claiming direction.
    public static let quietMinimumSeconds: Double = 3600   // 1 hour

    public static func classify(day: DateComponents, eventCount: Int,
                                monitoredSecondsThatDay: Double) -> DayState {
        if eventCount > 0 { return .events(eventCount) }
        return monitoredSecondsThatDay >= quietMinimumSeconds ? .quiet : .notMonitored
    }
}
