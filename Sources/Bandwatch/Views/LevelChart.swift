import SwiftUI
import BandwatchCore

/// Scrolling in-band level with the threshold drawn as a reference rule.
///
/// The threshold is a rule, not a second series — this is deliberately NOT a
/// two-series chart, and never a dual-axis one.
///
/// Rendered with `Canvas` rather than `Path`-backed views in a `ZStack`:
/// profiling showed the level math itself is negligible cost, while
/// rebuilding a ~1800-point history as SwiftUI view geometry every analysis
/// frame (21.5 Hz) drove CPU into view-graph layout. `Canvas` draws
/// imperatively with no per-point view nodes.
///
/// Takes the session itself (not a pre-read `history` array) so that this
/// view's own body is what registers the Observation dependency on
/// `session.levelHistory`. That confines invalidation on every published
/// display frame to just this chart, instead of forcing whatever ELSE reads
/// that array (e.g. `MonitorView.body`) to re-lay-out its entire subtree in
/// step.
struct LevelChart: View {
    @Bindable var session: MonitoringSession

    @Environment(\.colorScheme) private var scheme
    @State private var dragThresholdDBFS: Double?

    private let minDB = -100.0
    private let maxDB = 0.0

    /// dBFS values that get a horizontal gridline + label, so a level can be
    /// read off the chart rather than only inferred from the trace's shape.
    private let gridlineDBFS: [Double] = [-20, -40, -60, -80]

    private var history: [Double] { session.levelHistory }
    private var isEventActive: Bool { session.detectorState == .recording }

    private var thresholdDBFS: Double {
        get { session.detectorConfig.triggerDBFS }
        nonmutating set { session.detectorConfig.triggerDBFS = newValue }
    }

    /// The threshold to render: the in-progress drag value while dragging,
    /// otherwise the bound value. Keeping the label and rule in sync avoids
    /// showing a stale number next to a rule that has already moved.
    private var displayedThresholdDBFS: Double {
        dragThresholdDBFS ?? thresholdDBFS
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Band level")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(displayedThresholdDBFS, specifier: "%.1f") dBFS threshold")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.mutedInk(scheme))
            }
            .foregroundStyle(Palette.primaryInk(scheme))

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawBackground(context, size: size)
                        if isEventActive {
                            drawEventFill(context, size: size)
                        }
                        // Gridlines are drawn behind both the trace and the
                        // threshold rule so the data always reads on top.
                        drawGridLines(context, size: size)
                        drawLevelTrace(context, size: size)
                        drawThresholdRule(context, size: size)
                    }

                    gridlineLabels(in: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(thresholdDragGesture(height: geo.size.height))
            }
        }
    }

    // MARK: Geometry
    //
    // Preserved exactly: these are verified exact inverse pairs, and the
    // drag interaction depends on that.

    private func yPosition(forDB db: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, minDB), maxDB)
        let t = (clamped - minDB) / (maxDB - minDB)
        return height * (1 - CGFloat(t))
    }

    private func db(atY y: CGFloat, height: CGFloat) -> Double {
        let t = Double(1 - max(0, min(y, height)) / height)
        return minDB + t * (maxDB - minDB)
    }

    // MARK: Drawing

    private func drawBackground(_ context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.surface(scheme)))
    }

    private func drawEventFill(_ context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.eventFill(scheme)))
    }

    private func drawGridLines(_ context: GraphicsContext, size: CGSize) {
        for db in gridlineDBFS {
            let y = yPosition(forDB: db, height: size.height)
            let rect = CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)
            context.fill(Path(rect), with: .color(Palette.grid(scheme)))
        }
    }

    private func drawLevelTrace(_ context: GraphicsContext, size: CGSize) {
        guard history.count > 1 else { return }
        let step = size.width / CGFloat(max(history.count - 1, 1))
        var path = Path()
        for (i, db) in history.enumerated() {
            let point = CGPoint(x: CGFloat(i) * step,
                                y: yPosition(forDB: db, height: size.height))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        context.stroke(path, with: .color(Palette.series(scheme)), lineWidth: 2)
    }

    private func drawThresholdRule(_ context: GraphicsContext, size: CGSize) {
        // Rendered as a reference rule, never a second data series: solid
        // fill, no legend, distinct color from the trace (see Palette).
        let y = yPosition(forDB: displayedThresholdDBFS, height: size.height)
        let rect = CGRect(x: 0, y: y - 1, width: size.width, height: 2)
        context.fill(Path(rect), with: .color(Palette.threshold(scheme)))
    }

    // MARK: Labels

    private func gridlineLabels(in size: CGSize) -> some View {
        // Plain-number labels at the left edge, vertically centered on their
        // line; the axis unit (dBFS) is established once in the header
        // rather than repeated on every line.
        ForEach(gridlineDBFS, id: \.self) { db in
            let y = yPosition(forDB: db, height: size.height)
            Text("\(Int(db))")
                .font(.system(size: 8))
                .foregroundStyle(Palette.mutedInk(scheme))
                .padding(.leading, 2)
                .frame(width: size.width, alignment: .leading)
                .position(x: size.width / 2, y: y)
        }
    }

    private func thresholdDragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Track locally per frame only. Writing `thresholdDBFS` here
                // would forward through `DetectorConfig.didSet` into
                // `EventDetector.config.didSet`, which calls `reset()` on any
                // change — silently discarding any candidate or in-progress
                // event on every pixel of the drag.
                let candidate = db(atY: value.location.y, height: height)
                guard candidate.isFinite else { return }
                dragThresholdDBFS = candidate
            }
            .onEnded { value in
                defer { dragThresholdDBFS = nil }
                let candidate = db(atY: value.location.y, height: height)
                // At degenerate (zero-height) layout this division can yield
                // NaN. Never let a non-finite value reach the bound config.
                guard candidate.isFinite else { return }
                thresholdDBFS = candidate
            }
    }
}
