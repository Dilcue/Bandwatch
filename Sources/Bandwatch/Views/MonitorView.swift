import SwiftUI
import BandwatchCore

/// Top-level monitor window.
///
/// `body` deliberately reads NO fast-changing session state (`latestFrame`,
/// `levelHistory`, `suggestedThresholdDBFS`) directly. Profiling a 30-minute
/// run found the DSP pipeline itself costs 0.007 ms/frame -- negligible --
/// while CPU was dominated by SwiftUI view-graph layout, because reading
/// those properties here made THIS view (the entire tree: presets row,
/// response picker, readout strings, axis labels, buttons) the one that
/// Observation tracks as dependent on them, so every analysis frame
/// invalidated and re-laid-out everything, 21.5 times per second, when only
/// the two charts actually changed. Each child view below is handed
/// `session` itself and reads only what it needs from within its OWN body,
/// which confines invalidation to just the child that actually changed.
struct MonitorView: View {
    @Bindable var session: MonitoringSession
    let scheduler: MonitoringScheduler
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status indicators (state, recording, banners) — full width on top.
            StatusSection(session: session)
            RecordingRow(status: session.recordingStatus)

            // Configuration on the left; the Start/Stop button with the schedule
            // directly beneath it on the right. Both columns are top-aligned, so
            // the control block lines up with the Input row. Start is the first
            // item in its own fixed-width, leading-aligned column, so it stays
            // put when the schedule expands — it never moves.
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    StartStopButton(session: session)
                    ScheduleRow(scheduler: scheduler, session: session)
                }
                .frame(width: 340, alignment: .leading)

                PreferencesSection(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Extra breathing room separating the status/config band above from
            // the charts below.
            .padding(.vertical, 10)

            SpectrumChart(session: session, sampleRate: 44100, fftSize: 8192)
                .frame(height: 180)

            LevelChart(session: session)
                .frame(height: 140)

            ReadoutSection(session: session)
        }
        .padding(16)
        // Top-aligned so that if the window is ever shorter than the content, it
        // clips off the BOTTOM (readouts) rather than pushing the header up.
        .frame(minWidth: 640, minHeight: 600, alignment: .top)
        .background(Palette.surface(scheme))
    }
}

/// The Start/Stop button — the top item of the top-right control column,
/// directly above the schedule. Reads `session.isRunning` (observed) for its
/// label and action. Disabled while stopped with no usable input device
/// selected (nothing to capture from), so Start can't be pressed into a
/// no-op; Stop is never disabled.
private struct StartStopButton: View {
    let session: MonitoringSession
    var body: some View {
        Button(session.isRunning ? "Stop Monitoring" : "Start Monitoring") {
            if session.isRunning {
                session.stop()
            } else {
                Task { await session.start() }
            }
        }
        .disabled(!session.isRunning && !session.hasUsableSelectedDevice())
        .help(session.isRunning || session.hasUsableSelectedDevice() ? "" : "Choose an input device first.")
    }
}

/// Header dot/text plus the error, no-signal, and device-disconnect banners.
/// All of these depend only on `isRunning`, `inputHealth`, `lastError`, and
/// `captureConnection` -- state transitions that change rarely -- never on
/// the per-frame spectrum/level data, so this section's re-renders are cheap
/// and infrequent.
private struct StatusSection: View {
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = session.lastError {
                errorBanner(error)
            }

            // Awaiting-reconnect, no-signal, and armed-idle are chained into a
            // single if/else-if so at most one ever renders. They are NOT
            // mutually exclusive by construction: a scheduled start on an
            // already-missing device can leave `armedDeviceMissing == true`
            // for up to one tick while `captureConnection` has already
            // flipped to `.awaitingReconnect`, so without this chaining both
            // banners could render together with contradictory messaging.
            // Order below is most-specific/active state first: an active
            // disconnect during a running session, then no-signal during a
            // running session, then armed-idle while stopped (see
            // `MonitoringScheduler.updateArmedIdleDeviceWatch`).
            if let name = awaitingReconnectName {
                deviceDisconnectBanner(name)
            } else if showingNoSignal {
                noSignalBanner
            } else if session.armedDeviceMissing {
                armedDeviceMissingBanner
            }
        }
    }

    private var showingNoSignal: Bool {
        session.isRunning && session.inputHealth == .noSignal
    }

    private var awaitingReconnectName: String? {
        guard session.isRunning else { return nil }
        if case let .awaitingReconnect(name) = session.captureConnection { return name }
        return nil
    }

    private var header: some View {
        // Start/Stop lives in the top-right control block, directly above the
        // schedule — see MonitorView.body. This is just the status dot + text.
        HStack {
            Circle()
                .fill(headerDotColor)
                .frame(width: 8, height: 8)
            Text(headerText)
                .font(.headline)
                .foregroundStyle(Palette.primaryInk(scheme))
        }
    }

    private var headerDotColor: Color {
        guard session.isRunning else { return Palette.mutedInk(scheme) }
        if awaitingReconnectName != nil { return Palette.warning(scheme) }
        return showingNoSignal ? Palette.warning(scheme) : Color.green
    }

    private var headerText: String {
        guard session.isRunning else { return "Stopped" }
        if awaitingReconnectName != nil { return "Monitoring — input disconnected" }
        return showingNoSignal ? "Monitoring — no input signal" : "Monitoring"
    }

    private var noSignalBanner: some View {
        // The warning color is a bright gold in dark mode and a dark amber in
        // light mode (see Palette.warning), so the readable text color flips
        // opposite the scheme -- the reverse of the always-white error banner,
        // whose red background stays dark in both modes.
        Text("No input signal for an extended period. This usually means the microphone, interface, or mixer is off, muted, or disconnected. Monitoring is continuing and will recover automatically if the signal returns.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(scheme == .dark ? .black : .white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warning(scheme).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func deviceDisconnectBanner(_ name: String) -> some View {
        Text("Input “\(name)” was disconnected. Monitoring is paused and this interval is logged as a coverage gap. It will resume automatically when “\(name)” is reconnected.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(scheme == .dark ? .black : .white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warning(scheme).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Named when the scheduler knows what was selected (the normal case);
    /// falls back to unnamed copy only if nothing is available to name.
    private var armedDeviceMissingBanner: some View {
        let text: String
        if let name = session.selectedDeviceDisplayName() {
            text = "Scheduled input “\(name)” is unavailable — reconnect before the next window."
        } else {
            text = "Scheduled input is unavailable — reconnect before the next window."
        }
        return Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(scheme == .dark ? .black : .white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warning(scheme).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func errorBanner(_ error: CaptureError) -> some View {
        let message: String
        switch error {
        case .permissionDenied:
            message = "Microphone access was declined. Grant it in System Settings › Privacy & Security › Microphone, or if Bandwatch isn't listed there, quit and relaunch the app so it can ask again."
        case .noInputDevice:
            message = "No audio input device found."
        case .engineStartFailed(let detail):
            message = "Could not start audio: \(detail)"
        case .captureStalled:
            message = "Audio input stopped responding and monitoring has halted. Check your microphone/input device, then press Start to resume."
        }
        return Text(message)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Recording status readout: is audio actually being written to disk, and is
/// that writing healthy. A separate child view -- reading only
/// `session.recordingStatus`, handed down as a plain (non-`@Bindable`) value
/// -- so its per-poll invalidation (1 Hz, see `MonitoringSession`'s
/// `recordingStatusTask`) never re-lays-out the presets row, the response
/// picker, or the charts. Same isolation discipline that took CPU from ~29%
/// to ~8% in M1-M2.
///
/// Deliberately does not conflate "recording" with "recording well": a
/// session can have `isRecording == true` while every write is failing (a
/// full disk keeps `isRecording` true), which is exactly the deceptive
/// "looks healthy, records nothing" failure this row exists to prevent. The
/// indicator therefore reflects `consecutiveWriteFailures`, not merely
/// `isRecording`, and the failure/gap counts below are shown whenever they
/// are non-zero, not just alongside `lastError` (which the next unrelated
/// message can silently overwrite).
private struct RecordingRow: View {
    let status: RecordingStatus?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(indicatorText)
                    .foregroundStyle(Palette.primaryInk(scheme))
                if let seg = status?.currentSegment {
                    Text(seg).foregroundStyle(Palette.mutedInk(scheme))
                }
                Text("Clips: \(status?.eventsWritten ?? 0)")
                    .foregroundStyle(Palette.primaryInk(scheme))
                if let free = status?.freeBytes {
                    Text(String(format: "Free: %.1f GB", Double(free) / 1_073_741_824))
                        .foregroundStyle(Palette.mutedInk(scheme))
                }
            }
            .font(.system(size: 11, design: .monospaced))

            if let status, status.consecutiveWriteFailures > 0 {
                // Monotonic health, unlike `lastError` -- non-zero means
                // writes are failing RIGHT NOW, not merely that one failed
                // at some point in the past. Shown prominently, in the same
                // red used for capture-failure errors elsewhere in this
                // view, because "recording" while every write fails is
                // exactly the false-healthy state this row must never show.
                Text("Write failures: \(status.consecutiveWriteFailures) in a row — audio is NOT being saved")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let status, status.staleOpenGaps > 0 || status.discardedStubCount > 0
                || status.droppedArchiveWindowCount > 0 {
                // staleOpenGaps/discardedStubCount indicate lost/unaccounted-
                // for coverage from BEFORE this run (a prior crash's
                // unresolved gap, or archive segments too short to
                // finalize); droppedArchiveWindowCount is THIS run's own
                // disk-stall drops (I3) -- all three are amber rather than
                // the red used for write failures above, since none is
                // necessarily an ongoing failure at this instant.
                Text(coverageWarningText(status))
                    .font(.callout)
                    .foregroundStyle(scheme == .dark ? .black : .white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.warning(scheme).opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let err = status?.lastError {
                // A write failure must be visible, never silent.
                Text("Write problem: \(err)")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.warning(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Health, not merely intent: green only when actually recording AND no
    /// writes are currently failing. A climbing `consecutiveWriteFailures`
    /// must never read as green.
    private var indicatorColor: Color {
        guard status?.isRecording == true else { return Palette.mutedInk(scheme) }
        return (status?.consecutiveWriteFailures ?? 0) > 0 ? Color.red : Color.green
    }

    private var indicatorText: String {
        guard status?.isRecording == true else { return "Not recording" }
        return (status?.consecutiveWriteFailures ?? 0) > 0 ? "Recording — writes failing" : "Recording"
    }

    private func coverageWarningText(_ status: RecordingStatus) -> String {
        var parts: [String] = []
        if status.staleOpenGaps > 0 {
            parts.append("\(status.staleOpenGaps) unresolved coverage gap(s) from a previous run")
        }
        if status.discardedStubCount > 0 {
            parts.append("\(status.discardedStubCount) archive segment(s) discarded, \(status.discardedFrames) frames lost")
        }
        if status.droppedArchiveWindowCount > 0 {
            // A drop mid-segment, unlike a discarded stub, does not shrink
            // `eventsWritten`/file count -- the archive file it landed in
            // still exists and still opens, just with a splice a naive
            // reader would not detect from the filename or duration alone.
            parts.append("\(status.droppedArchiveWindowCount) archive window(s) dropped (disk stall)")
        }
        return parts.joined(separator: "; ")
    }
}

/// Configuration controls, shown above the charts: which input device, which
/// band preset, and the time response. Like the sections below, this view's own
/// `body` reads nothing from `session` -- it only hands the session down to its
/// children -- so it never itself becomes an Observation dependency; each child
/// re-renders independently based solely on what THAT child reads.
private struct PreferencesSection: View {
    let session: MonitoringSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InputDeviceRow(session: session)
            PresetsRow(session: session)
            SpeechWarningRow(session: session)
            ResponsePicker(session: session)
            SuggestedThresholdRow(session: session)
        }
    }
}

/// Automatic start/stop window, independent of manual Start/Stop. Only
/// re-renders when `schedule` changes (toggle flips, time drags), never on
/// analysis frames. Also holds `session` (read-only) solely to check
/// `hasUsableSelectedDevice()` when the toggle is switched on -- enabling a
/// schedule with no usable device armed would otherwise fail silently every
/// night until someone happened to notice.
private struct ScheduleRow: View {
    @Bindable var scheduler: MonitoringScheduler
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme
    @State private var showingDevicePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Automatic Schedule", isOn: $scheduler.schedule.isEnabled)
                .onChange(of: scheduler.schedule.isEnabled) { wasEnabled, isEnabled in
                    // Only the OFF -> ON transition is of interest; disabling
                    // never needs the prompt.
                    guard isEnabled, !wasEnabled, !session.hasUsableSelectedDevice() else { return }
                    showingDevicePrompt = true
                }

            // The pickers and notes ALWAYS occupy their space — invisible and
            // non-interactive until the schedule is enabled — so the column is
            // permanently at its full height and toggling never reflows the
            // window.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    DatePicker("From", selection: startBinding, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: endBinding, displayedComponents: .hourAndMinute)
                }
                .controlSize(.small)
                // REQUIRED ownership note (spec): the schedule only ever starts
                // and stops sessions it started itself; manual sessions are left
                // alone. The hard width cap forces wrapping regardless of the
                // picker row's width.
                Text("Scheduler starts and stops its own sessions.")
                    .font(.caption2).foregroundStyle(Palette.mutedInk(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 324, alignment: .leading)
                Text("Monitoring you start manually keeps running until you stop it.")
                    .font(.caption2).foregroundStyle(Palette.mutedInk(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 324, alignment: .leading)
            }
            .opacity(scheduler.schedule.isEnabled ? 1 : 0)
            .disabled(!scheduler.schedule.isEnabled)
            .accessibilityHidden(!scheduler.schedule.isEnabled)
        }
        // Directs the user to the Input picker rather than embedding a
        // second device list here -- there is exactly one place devices are
        // chosen, and this alert should not become a second one.
        .alert("Choose an available input device for scheduled monitoring", isPresented: $showingDevicePrompt) {
            Button("OK") { }
        }
    }

    // DatePicker works in Date; bridge to minutes-of-day (today at that time).
    private var startBinding: Binding<Date> { minuteBinding(\.startMinuteOfDay) }
    private var endBinding: Binding<Date> { minuteBinding(\.endMinuteOfDay) }
    private func minuteBinding(_ kp: WritableKeyPath<MonitoringSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = scheduler.schedule[keyPath: kp]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                scheduler.schedule[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// Privacy guardrail: warns when the current band overlaps the
/// speech-intelligibility range, so the user knows recordings may capture
/// understandable conversation before exporting or sharing a bundle. Reads only
/// `band` (changes on preset taps / drags), never per-frame data.
private struct SpeechWarningRow: View {
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if session.band.overlapsSpeechRange {
            Label("This band overlaps speech frequencies — recordings may contain intelligible conversation.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.warning(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Live readout and the suggested-threshold action, below the charts where the
/// values they reflect are visible. Reads nothing fast-changing in its own body
/// (see `PreferencesSection`).
private struct ReadoutSection: View {
    let session: MonitoringSession

    var body: some View {
        ReadoutRow(session: session)
    }
}

/// Chooses which input device to monitor. There is no "System Default"
/// option — the spec requires an explicit choice, since a silent OS-level
/// swap of the actual capture device is exactly the ambiguity this feature
/// removes. Shows a placeholder until a device is chosen; disabled while
/// monitoring — change the input while stopped.
private struct InputDeviceRow: View {
    @Bindable var session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Input:")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedInk(scheme))
                    .frame(width: 72, alignment: .leading)
                Picker("Input", selection: $session.selectedInputDeviceUID) {
                    // Placeholder only -- shown solely so the menu isn't
                    // blank when nothing is chosen yet; it drops out of the
                    // list the moment a real device is selected, so it is
                    // never a standing "no device" choice a user can return
                    // to (unlike the old "System Default" row).
                    if session.selectedInputDeviceUID == nil {
                        Text("Select input device…").tag(String?.none)
                    }
                    ForEach(session.availableInputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 260, alignment: .leading)
                .disabled(session.isRunning)
            }
            if let notice = session.inputNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(Palette.mutedInk(scheme))
            }
        }
        .onAppear { session.refreshInputDevices() }
    }
}

/// Only re-renders when `band` changes (button taps), never on analysis
/// frames.
private struct PresetsRow: View {
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text("Presets:")
                .font(.caption)
                .foregroundStyle(Palette.mutedInk(scheme))
                .frame(width: 72, alignment: .leading)
            Button("Bass 20–120 Hz") { session.band = .bassSubwoofer }
            Button("Whine 2–8 kHz") { session.band = .applianceWhine }
            Button("Beeping 1–4 kHz") { session.band = .beeping }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Only re-renders when `timeWeighting` changes, never on analysis frames.
private struct ResponsePicker: View {
    @Bindable var session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text("Response:")
                .font(.caption)
                .foregroundStyle(Palette.mutedInk(scheme))
                .frame(width: 72, alignment: .leading)
            Picker("Response", selection: $session.timeWeighting) {
                ForEach(TimeWeighting.allCases, id: \.self) { weighting in
                    Text(weighting.displayName).tag(weighting)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140, alignment: .leading)
        }
    }
}

/// Band and event-count read here directly (both change rarely: band on
/// preset/drag changes, events only at event boundaries). The live level is
/// delegated to `LiveLevelText`, its own child view, so its per-frame
/// invalidation only re-lays-out that one piece of text, not this whole row.
private struct ReadoutRow: View {
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Text("Band: \(Int(session.band.lowHz))–\(Int(session.band.highHz)) Hz")
            LiveLevelText(session: session)
            if let lastEventAt = session.lastEventAt {
                Text("Last event: \(lastEventAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Last event: none")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.primaryInk(scheme))
    }
}

/// The one piece of UI that legitimately needs to update every published
/// display frame. Isolated so that update never drags the presets row, the
/// response picker, or the suggested-threshold button along with it.
private struct LiveLevelText: View {
    let session: MonitoringSession

    var body: some View {
        Text("Level: \(session.latestFrame?.bandLevelDBFS ?? -120, specifier: "%.1f") dBFS")
    }
}

/// A persistent configuration row showing the suggested detection threshold.
/// Reads "Unknown" until the baseline matures (~3 minutes of monitoring), then
/// shows the value with a button to apply it. Reads `suggestedThresholdDBFS` on
/// its own, isolated from the rest of the controls: its appearance, once the
/// baseline matures, was observed as a step in the CPU curve at ~3 minutes --
/// corroborating evidence that reading it in the shared parent body (as it used
/// to) pulled it into the same per-frame layout pass as everything else.
private struct SuggestedThresholdRow: View {
    let session: MonitoringSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text("Suggested Threshold:")
                .font(.caption)
                .foregroundStyle(Palette.mutedInk(scheme))
            if let suggested = session.suggestedThresholdDBFS {
                Text("\(String(format: "%.1f", suggested)) dBFS")
                    .font(.caption)
                    .foregroundStyle(Palette.primaryInk(scheme))
                Button("Use") { session.applySuggestedThreshold() }
                    .controlSize(.small)
            } else {
                Text("Will Be Determined")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedInk(scheme))
            }
        }
        // Nudge down so the spacing to the Response row above matches the
        // gaps between the other configuration rows.
        .padding(.top, 4)
    }
}
