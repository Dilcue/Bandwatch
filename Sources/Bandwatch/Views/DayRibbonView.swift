import SwiftUI
import BandwatchCore

/// One full calendar day on a 24-hour axis: events as marks (height = peak dBFS), gaps shaded.
struct DayRibbonView: View {
    @Bindable var model: ReviewModel
    let day: Date
    let onSelect: (EventRecord) -> Void
    @Environment(\.colorScheme) private var scheme

    // level mapping: -80…0 dBFS -> 0…1 height
    private func h(_ dbfs: Double) -> Double { min(max((dbfs + 80) / 80, 0), 1) }

    /// Hour offsets from window start (midnight) at the 3-hour ticks, and
    /// their labels: 12a 3a 6a 9a 12p 3p 6p 9p 12a. Fractions share the exact
    /// same `start`/`span` coordinate system the event marks use.
    private static let tickHours: [Double] = [0, 3, 6, 9, 12, 15, 18, 21, 24]
    private static let tickLabels: [String] = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p", "12a"]
    private static let ribbonHeight: CGFloat = 90
    private static let axisHeight: CGFloat = 14

    private func fraction(forHour hour: Double) -> Double { hour / 24.0 }

    var body: some View {
        let events = model.eventsForDay(of: day)
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let span = 24.0 * 3600   // full calendar day

        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Palette.surface(scheme)
                    // faint gridlines at each 3-hour tick, behind marks/gaps
                    ForEach(Self.tickHours, id: \.self) { hour in
                        Rectangle()
                            .fill(Palette.grid(scheme).opacity(0.5))
                            .frame(width: 1)
                            .position(x: geo.size.width * fraction(forHour: hour), y: geo.size.height / 2)
                    }
                    // gaps
                    ForEach(model.gaps, id: \.id) { g in
                        let gs = max(g.startedAt.timeIntervalSince(start), 0) / span
                        let ge = min((g.endedAt ?? start.addingTimeInterval(span)).timeIntervalSince(start), span) / span
                        if ge > gs {
                            Rectangle().fill(Palette.mutedInk(scheme).opacity(0.18))
                                .frame(width: geo.size.width * (ge - gs))
                                .offset(x: geo.size.width * gs)
                        }
                    }
                    // events
                    ForEach(events, id: \.id) { e in
                        let x = e.startedAt.timeIntervalSince(start) / span
                        if x >= 0 && x <= 1 {
                            Rectangle().fill(Palette.series(scheme))
                                .frame(width: 3, height: geo.size.height * h(e.peakDBFS))
                                .offset(x: geo.size.width * x)
                                .onTapGesture { onSelect(e) }
                        }
                    }
                }
            }
            .frame(height: Self.ribbonHeight)

            // time axis strip, below the ribbon, sharing the same x mapping.
            // The first ("12a" at midnight) and last ("12a" at next midnight)
            // labels sit exactly on the 0/1 edges, so they're left/right
            // aligned within the full-width strip instead of centered on the
            // edge — centering would clip half the glyph off the view.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Self.tickHours.indices, id: \.self) { i in
                        let label = Text(Self.tickLabels[i])
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.mutedInk(scheme))
                        if i == 0 {
                            label
                                .frame(width: geo.size.width, alignment: .leading)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        } else if i == Self.tickHours.count - 1 {
                            label
                                .frame(width: geo.size.width, alignment: .trailing)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        } else {
                            label
                                .position(x: geo.size.width * fraction(forHour: Self.tickHours[i]), y: geo.size.height / 2)
                        }
                    }
                }
            }
            .frame(height: Self.axisHeight)
        }
    }
}
