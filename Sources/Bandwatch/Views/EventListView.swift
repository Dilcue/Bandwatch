import SwiftUI
import BandwatchCore

extension EventRecord: Identifiable {}

struct EventListView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        Table(model.events, selection: Binding(
            get: { model.selectedEventID },
            set: { model.selectedEventID = $0 }
        )) {
            TableColumn("Date") { e in Text(Self.day(e.startedAt)) }
            TableColumn("Start") { e in Text(Self.time(e.startedAt)) }
            TableColumn("Duration") { e in Text(String(format: "%.1f s", e.durationSec)) }
            TableColumn("Peak dBFS") { e in Text(String(format: "%.1f", e.peakDBFS)) }
            TableColumn("Band") { e in Text("\(Int(e.bandLowHz))–\(Int(e.bandHighHz)) Hz") }
        }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static func day(_ d: Date) -> String { dayFmt.string(from: d) }
    static func time(_ d: Date) -> String { timeFmt.string(from: d) }
}
