import SwiftUI
import BandwatchCore

/// Month grid, one cell per day, four visually distinct states.
///
/// Sequential single-hue ramp for event counts (never rainbow). "Quiet" is the
/// surface colour; "not monitored" is a hatched cell — because a dead microphone
/// must never look like a quiet night. A future day (hasn't happened yet)
/// renders blank, distinct from both.
struct CalendarHeatmapView: View {
    @Bindable var model: ReviewModel
    let monthAnchor: Date
    var now: Date = Date()
    @Environment(\.colorScheme) private var scheme

    private let cols = 7

    /// Sunday-first weekday header, pinned regardless of locale `firstWeekday`.
    private static let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(28), spacing: 3), count: cols)
    }

    var body: some View {
        let days = Self.daysIn(month: monthAnchor)
        let maxCount = max(model.dailyCounts.map(\.count).max() ?? 1, 1)
        let leadingBlanks = Self.leadingBlankCount(month: monthAnchor)
        VStack(alignment: .leading, spacing: 3) {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Self.weekdaySymbols.indices, id: \.self) { i in
                    Text(Self.weekdaySymbols[i])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.mutedInk(scheme))
                        .frame(width: 28)
                }
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: 28, height: 28)
                }
                ForEach(days, id: \.self) { day in
                    cell(for: day, maxCount: maxCount)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for day: Date, maxCount: Int) -> some View {
        // Four honest states. A future day hasn't happened — render it blank, never
        // hatched (which would read as "we failed to monitor a day that passed").
        // Past days are classified from real span coverage: no span → notMonitored
        // (hatched), span but no events → quiet (surface), events → the ramp.
        if Calendar.current.startOfDay(for: day) > Calendar.current.startOfDay(for: now) {
            futureCell(for: day)
        } else {
            let monitored = model.monitoredSeconds(on: day)
            let state = model.dayState(for: day, monitoredSecondsThatDay: monitored)
            RoundedRectangle(cornerRadius: 4)
                .fill(fill(state, maxCount: maxCount))
                .overlay(hatch(state).clipShape(RoundedRectangle(cornerRadius: 4)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Palette.grid(scheme), lineWidth: 1))
                .frame(width: 28, height: 28)
                .overlay(Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 9)).foregroundStyle(Palette.mutedInk(scheme)))
                .onTapGesture { model.selectDay(day) }
        }
    }

    /// A day that hasn't happened yet: blank, no border, dimmed number. Distinct
    /// from both "quiet" (a real surface cell) and "not monitored" (hatched).
    @ViewBuilder
    private func futureCell(for day: Date) -> some View {
        Color.clear
            .frame(width: 28, height: 28)
            .overlay(Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 9)).foregroundStyle(Palette.mutedInk(scheme).opacity(0.3)))
    }

    private func fill(_ state: DayState, maxCount: Int) -> Color {
        switch state {
        case .events(let n):
            let t = Double(n) / Double(maxCount)      // 0…1
            return Palette.series(scheme).opacity(0.25 + 0.75 * t)
        case .quiet:        return Palette.surface(scheme)
        case .notMonitored: return Palette.surface(scheme)
        }
    }

    @ViewBuilder
    private func hatch(_ state: DayState) -> some View {
        if case .notMonitored = state {
            // diagonal hatch to mark "not monitored", distinct from quiet
            GeometryReader { g in
                Path { p in
                    var x = -g.size.height
                    while x < g.size.width {
                        p.move(to: CGPoint(x: x, y: g.size.height))
                        p.addLine(to: CGPoint(x: x + g.size.height, y: 0))
                        x += 6
                    }
                }.stroke(Palette.mutedInk(scheme).opacity(0.5), lineWidth: 1)
            }
        } else {
            EmptyView()
        }
    }

    static func daysIn(month: Date) -> [Date] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month))
        else { return [] }
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    /// Number of blank leading cells so day 1 lands under its real weekday,
    /// Sunday-first. `Calendar.component(.weekday, from:)` returns 1 for
    /// Sunday … 7 for Saturday independent of locale `firstWeekday`, so the
    /// blank count is simply `weekday - 1`.
    static func leadingBlankCount(month: Date) -> Int {
        let cal = Calendar.current
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: month))
        else { return 0 }
        return cal.component(.weekday, from: first) - 1
    }
}
