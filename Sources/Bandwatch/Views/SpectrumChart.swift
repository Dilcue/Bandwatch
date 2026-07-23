import SwiftUI
import BandwatchCore

/// Live magnitude spectrum on a logarithmic frequency axis.
///
/// Log axis is mandatory: on a linear axis 40 Hz and 60 Hz are indistinguishable,
/// which defeats the app's purpose. Drag horizontally to set the band.
///
/// Rendered with `Canvas` rather than `Path`-backed views in a `ZStack`:
/// profiling a 30-minute run showed the DSP pipeline costs 0.007 ms/frame
/// (negligible) while CPU was dominated by SwiftUI view-graph layout, because
/// rebuilding a ~4096-point `Path` as view geometry at 21.5 Hz runs every
/// point through diffing and layout. `Canvas` draws imperatively with no
/// per-point view nodes. The bin count drawn is also capped to at most one
/// point per horizontal pixel via `decimateForDisplay` (see BandwatchCore),
/// which keeps the maximum magnitude per pixel so narrow peaks survive.
///
/// Takes the session itself (not pre-read `magnitudes`/`band` values) so that
/// this view's own body is what registers the Observation dependency on
/// `session.latestFrame`. That confines invalidation on every analysis frame
/// to just this chart, instead of forcing whatever ELSE reads those values
/// (e.g. `MonitorView.body`) to re-lay-out its entire subtree in step.
struct SpectrumChart: View {
    @Bindable var session: MonitoringSession
    let sampleRate: Double
    let fftSize: Int

    @Environment(\.colorScheme) private var scheme
    @State private var dragStartHz: Double?
    @State private var dragBand: FrequencyBand?

    private let minHz = 20.0
    private var maxHz: Double { sampleRate / 2 }

    private var magnitudes: [Float] { session.latestFrame?.magnitudes ?? [] }

    /// Reserved strip along the bottom of the chart for the frequency axis
    /// labels, so they never overlap the plotted trace above them.
    private let labelGutterHeight: CGFloat = 14

    private let axisTickHz: [Double] = [20.0, 50.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spectrum")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.primaryInk(scheme))

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let height = plotHeight(for: size)
                        drawBackground(context, size: size)
                        drawBandRegion(context, size: size, height: height)
                        drawSpectrumTrace(context, size: size, height: height)
                    }

                    axisLabels(in: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(bandDragGesture(width: geo.size.width))
            }
        }
    }

    /// The vertical extent available to the plot itself, excluding the
    /// reserved label gutter at the bottom.
    private func plotHeight(for size: CGSize) -> CGFloat {
        max(size.height - labelGutterHeight, 0)
    }

    // MARK: Geometry
    //
    // Preserved exactly: these are verified exact inverse pairs, and the
    // drag interaction depends on that.

    private func xPosition(forHz hz: Double, width: CGFloat) -> CGFloat {
        let clamped = min(max(hz, minHz), maxHz)
        let t = (log10(clamped) - log10(minHz)) / (log10(maxHz) - log10(minHz))
        return CGFloat(t) * width
    }

    private func hz(atX x: CGFloat, width: CGFloat) -> Double {
        let t = Double(max(0, min(x, width)) / width)
        return pow(10, log10(minHz) + t * (log10(maxHz) - log10(minHz)))
    }

    // MARK: Drawing

    private func drawBackground(_ context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.surface(scheme)))
    }

    private func drawBandRegion(_ context: GraphicsContext, size: CGSize, height: CGFloat) {
        // While a drag is in progress, render from the local in-progress
        // selection so feedback stays continuous even though the bound
        // `session.band` (and everything downstream of it) only updates once,
        // on release.
        let displayBand = dragBand ?? session.band
        let x0 = xPosition(forHz: displayBand.lowHz, width: size.width)
        let x1 = xPosition(forHz: displayBand.highHz, width: size.width)
        let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: height)
        context.fill(Path(rect), with: .color(Palette.bandFill(scheme)))
    }

    private func drawSpectrumTrace(_ context: GraphicsContext, size: CGSize, height: CGFloat) {
        guard !magnitudes.isEmpty else { return }
        let binWidth = sampleRate / Double(fftSize)
        let pixelWidth = max(Int(size.width.rounded()), 1)

        let points = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: binWidth,
            minHz: minHz,
            maxHz: maxHz,
            pixelWidth: pixelWidth
        )
        guard !points.isEmpty else { return }

        var path = Path()
        var started = false
        for point in points {
            // Magnitude -> dBFS -> normalized height over a 100 dB window.
            let db = point.magnitude > 0 ? 20.0 * log10(Double(point.magnitude)) : BandLevelMeter.silenceFloorDBFS
            let norm = min(max((db + 100.0) / 100.0, 0), 1)

            let x = xPosition(forHz: point.hz, width: size.width)
            let y = height * (1 - CGFloat(norm))

            if started {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            }
        }
        context.stroke(path, with: .color(Palette.series(scheme)), lineWidth: 2)
    }

    private func axisLabels(in size: CGSize) -> some View {
        // Centered in the reserved bottom gutter, below the plot area, so
        // labels never sit on top of the trace.
        let labelY = size.height - labelGutterHeight / 2
        return ForEach(axisTickHz, id: \.self) { hz in
            let x = xPosition(forHz: hz, width: size.width)
            if x > 8 && x < size.width - 8 {
                Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.mutedInk(scheme))
                    .position(x: x, y: labelY)
            }
        }
    }

    private func bandDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStartHz == nil {
                    dragStartHz = hz(atX: value.startLocation.x, width: width)
                }
                guard let start = dragStartHz else { return }
                let current = hz(atX: value.location.x, width: width)
                // Only the local, drag-scoped state updates per frame. Writing
                // `session.band` here would fire `MonitoringSession.band.didSet`
                // on every pixel of the drag, blanking the very spectrum the
                // user is dragging against and re-running baseline calibration
                // dozens of times per gesture.
                if let newBand = FrequencyBand(lowHz: min(start, current),
                                               highHz: max(start, current)) {
                    dragBand = newBand
                }
            }
            .onEnded { value in
                defer {
                    dragStartHz = nil
                    dragBand = nil
                }
                guard let start = dragStartHz else { return }
                let current = hz(atX: value.location.x, width: width)
                // Commit exactly once. A degenerate (zero-width) drag makes
                // `FrequencyBand.init` return nil; in that case leave the
                // existing band untouched rather than writing garbage.
                if let newBand = FrequencyBand(lowHz: min(start, current),
                                               highHz: max(start, current)) {
                    session.band = newBand
                }
            }
    }
}
