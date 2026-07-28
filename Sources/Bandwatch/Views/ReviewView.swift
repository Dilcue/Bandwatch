import AppKit
import Combine
import SwiftUI
import BandwatchCore

struct ReviewView: View {
    @Bindable var model: ReviewModel
    @Environment(\.colorScheme) private var scheme
    @State private var player = ClipPlayer()
    @State private var exportStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let status = exportStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(Palette.mutedInk(scheme))
            }
            if let err = model.loadError {
                Text("No recordings yet — start monitoring to collect events. (\(err))")
                    .font(.callout)
                    .foregroundStyle(Palette.mutedInk(scheme))
                    .padding(.vertical, 8)
            }
            CalendarHeatmapView(model: model, monthAnchor: model.rangeEnd)
            DayRibbonView(model: model, day: model.selectedDay ?? model.rangeEnd, onSelect: selectAndPlay)
            playbackControls
            EventListView(model: model)
                .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(Palette.surface(scheme))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // When the Review window comes back to the front, reload data within
            // the CURRENT range so events recorded since it was last viewed show
            // up — without disturbing a range the user has narrowed (that's why
            // this is load(), not refresh()). onAppear handles the initial
            // full-span derive when the window first opens.
            if (note.object as? NSWindow)?.title == "Bandwatch Review" {
                model.load()
            }
        }
        .onChange(of: model.selectedEventID) { _, newID in
            guard let id = newID, let event = model.events.first(where: { $0.id == id }) else { return }
            player.play(url: URL(fileURLWithPath: event.clipPath))
        }
    }

    private func exportEvidenceBundle() {
        guard let data = model.currentReportData() else {
            exportStatus = "Nothing to export in this range."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bandwatch-Evidence.zip"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("bw-export-\(UUID().uuidString)")
        Task {
            do {
                let summary = try BundleExporter.export(data, to: dest, workDir: work)
                exportStatus = "Exported \(summary.clipsIncluded) clips (\(summary.clipsMissing) expired)."
            } catch {
                exportStatus = "Export failed: \(error)"
            }
        }
    }

    /// Selecting an event (from the ribbon or the event list, via
    /// `model.selectedEventID`) triggers playback through the shared
    /// `onChange` below, so both selection paths behave identically.
    private func selectAndPlay(_ event: EventRecord) {
        if model.selectedEventID == event.id {
            player.play(url: URL(fileURLWithPath: event.clipPath))
        } else {
            model.selectedEventID = event.id
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button(player.isPlaying ? "Stop" : "Play") {
                if player.isPlaying {
                    player.stop()
                } else if let event = model.selectedEvent {
                    player.play(url: URL(fileURLWithPath: event.clipPath))
                }
            }
            .disabled(!player.isPlaying && model.selectedEvent == nil)
            Text("Clips are band-filtered — low-frequency events (e.g. 20–120 Hz) can sound faint or silent on laptop speakers even when present.")
                .font(.caption)
                .foregroundStyle(Palette.mutedInk(scheme))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Review").font(.title2.weight(.semibold))
                .foregroundStyle(Palette.primaryInk(scheme))
            Spacer()
            DatePicker("From", selection: $model.rangeStart, displayedComponents: .date)
            DatePicker("To", selection: $model.rangeEnd, displayedComponents: .date)
            Text("\(model.events.count) events")
                .font(.callout).foregroundStyle(Palette.mutedInk(scheme))
            Button("Refresh") { model.load() }   // reload data, keep the chosen range
            Button("Export Evidence Bundle…") { exportEvidenceBundle() }
        }
    }
}
