import Foundation

/// Pure coverage arithmetic shared by the evidence report
/// (`EventStore.coverageTotals`) and the Review calendar heatmap
/// (`ReviewModel.monitoredSeconds`). Kept in one place so the two surfaces can
/// never disagree.
///
/// `monitored = |union(spans) ∩ window| − |union(gaps) ∩ window|`, clamped ≥ 0,
/// where `window = [from, min(to, now)]`.
///
/// Two properties this enforces — both were violated by the earlier
/// sum-and-clamp-to-`to` implementation, which zeroed a live report:
///
/// 1. **Coverage never counts the future.** The window upper bound is capped at
///    `now`, and an OPEN gap (`endedAt == nil`, an interruption still ongoing)
///    extends only through `now` — never to the range end. A report generated
///    for "today" has `to` at midnight tonight; without this cap an open gap was
///    projected hours into the future.
/// 2. **Overlapping intervals are unioned, not summed.** Two concurrent gaps
///    (e.g. a write-failure and a device-loss reported at the same instant)
///    count once, not twice. Summing let their overlap be double-subtracted from
///    monitored time.
public enum CoverageMath {
    public struct Totals: Equatable, Sendable {
        public let monitoredSeconds: Double
        public let gapSeconds: Double
    }

    public static func totals(spans: [SpanRecord], gaps: [GapRecord],
                              from: Date, to: Date, now: Date) -> Totals {
        // Never count into the future: an open-ended range (a report for today)
        // stops at `now`, not at midnight tonight.
        let upper = min(to, now)
        guard upper > from else { return Totals(monitoredSeconds: 0, gapSeconds: 0) }

        let spanSecs = unionSeconds(spans.map { ($0.startedAt, $0.endedAt) },
                                    from: from, to: upper)
        // An open gap is ongoing as of `now`, so that is its provisional end.
        let gapSecs = unionSeconds(gaps.map { ($0.startedAt, $0.endedAt ?? now) },
                                   from: from, to: upper)
        return Totals(monitoredSeconds: max(spanSecs - gapSecs, 0), gapSeconds: gapSecs)
    }

    /// Total length, in seconds, of the union of `intervals` intersected with
    /// `[from, to]`. Overlapping and touching intervals merge, so shared time is
    /// counted once.
    static func unionSeconds(_ intervals: [(Date, Date)], from: Date, to: Date) -> Double {
        let clamped = intervals
            .map { (max($0.0, from), min($0.1, to)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var total = 0.0
        var curStart: Date?
        var curEnd: Date?
        for iv in clamped {
            guard let cs = curStart, let ce = curEnd else {
                curStart = iv.0; curEnd = iv.1
                continue
            }
            if iv.0 <= ce {                       // overlaps/touches the open run — extend
                if iv.1 > ce { curEnd = iv.1 }
            } else {                              // disjoint — close the run, start a new one
                total += ce.timeIntervalSince(cs)
                curStart = iv.0; curEnd = iv.1
            }
        }
        if let cs = curStart, let ce = curEnd { total += ce.timeIntervalSince(cs) }
        return total
    }
}
