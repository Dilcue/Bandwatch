import Foundation

/// Rolling estimate of the quiet-room level in the selected band.
///
/// Uses the median rather than the mean: the mean is dragged upward by the very
/// events being measured, the median is not.
public final class BaselineEstimator {
    public static let margin: Double = 12.0
    // At ~21.5 analysis frames/sec (hop 2048 / sample rate 44100), the old
    // value of 600 was only ~28 seconds — far short of the spec's promise
    // that the suggestion appears "after several minutes of monitoring". A
    // user who starts the app while the target noise is already happening
    // would, after 28s, be offered a threshold 12 dB above the *noise itself*
    // rather than the quiet room; accepting it silently disables detection
    // for the rest of the run. Raised to correspond to at least 3 minutes:
    // 3 min * 60 s/min * 21.5 frames/s ≈ 3870 frames.
    public static let minimumSamples: Int = 3870

    private let windowSize: Int
    private var samples: [Double] = []
    private var writeIndex = 0
    private var count = 0

    // Must be >= minimumSamples: a rolling window smaller than the minimum
    // sample count needed to produce a suggestion would have already evicted
    // some of those samples by the time the suggestion appears, making the
    // "minimum" a lie. The old default (3600) satisfied that against the old
    // minimumSamples (600), but minimumSamples raised above to 3870 now
    // exceeds it, so the default here must move in lockstep — defaulting
    // directly to minimumSamples keeps that invariant true by construction
    // rather than by two independently-chosen constants staying in sync.
    public init(windowSize: Int = BaselineEstimator.minimumSamples) {
        precondition(windowSize > 0)
        self.windowSize = windowSize
        self.samples = [Double](repeating: 0, count: windowSize)
    }

    public func add(level: Double) {
        samples[writeIndex] = level
        writeIndex = (writeIndex + 1) % windowSize
        count += 1
    }

    public var baselineDBFS: Double? {
        guard count >= Self.minimumSamples else { return nil }
        let filled = min(count, windowSize)
        // `samples[0..<filled]` is PHYSICAL storage order (index by
        // writeIndex position), not chronological order — once the window
        // has wrapped, index 0 is not the oldest sample and index `filled-1`
        // is not the newest. Sorting for the median is safe regardless of
        // order, so this is fine here. It is NOT safe to reuse this slice for
        // any mean-of-recent-N or trend/rate-of-change calculation — a future
        // review-UI feature reaching for "the last 30 seconds" via this array
        // would silently get an arbitrary physical-order subrange instead.
        var window = Array(samples[0..<filled])
        window.sort()
        let mid = filled / 2
        if filled % 2 == 0 {
            return (window[mid - 1] + window[mid]) / 2
        }
        return window[mid]
    }

    public var suggestedThresholdDBFS: Double? {
        baselineDBFS.map { $0 + Self.margin }
    }

    public func reset() {
        samples = [Double](repeating: 0, count: windowSize)
        writeIndex = 0
        count = 0
    }
}
