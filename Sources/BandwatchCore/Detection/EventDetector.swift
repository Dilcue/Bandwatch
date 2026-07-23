import Foundation

public enum DetectorState: Equatable, Sendable {
    case idle
    case candidate
    case recording
}

/// Pure threshold state machine converting a level stream into discrete events.
///
/// Performs no I/O and never reads the clock — time is always supplied by the
/// caller. This is what makes the app's trickiest logic exhaustively testable.
public final class EventDetector {
    public private(set) var state: DetectorState = .idle

    public var config: DetectorConfig {
        didSet {
            guard config != oldValue else { return }
            reset()
        }
    }

    // In-progress event accumulation.
    private var eventStart: TimeInterval = 0
    private var lastAboveRelease: TimeInterval = 0
    private var peak: Double = -.infinity
    private var levelSum: Double = 0
    private var levelCount: Int = 0

    public init(config: DetectorConfig) {
        self.config = config
    }

    /// Feeds one level sample. Returns an event if one completed at this sample.
    public func process(level: Double, at time: TimeInterval) -> DetectedEvent? {
        switch state {
        case .idle:
            if level >= config.triggerDBFS {
                beginEvent(level: level, at: time)
                state = .candidate
            }
            return nil

        case .candidate:
            accumulate(level: level, at: time)
            if level < config.releaseDBFS {
                // Fell away before qualifying — discard.
                reset()
                return nil
            }
            if time - eventStart >= config.minimumDuration {
                state = .recording
            }
            return nil

        case .recording:
            accumulate(level: level, at: time)

            // Cap on continuous noise: emit and immediately start a new event.
            // End at lastAboveRelease, not the raw cap time: if the level
            // dipped below release shortly before the cap fired, those
            // trailing quiet samples were already excluded from peak/mean by
            // the `accumulate` guard above, so duration must exclude them
            // too, exactly as the release path below does.
            if time - eventStart >= config.maximumDuration {
                let event = buildEvent(endingAt: lastAboveRelease)
                beginEvent(level: level, at: time)
                state = level >= config.triggerDBFS ? .recording : .candidate
                return event
            }

            // Release only after the level has stayed below the release
            // threshold for the full release time.
            if time - lastAboveRelease >= config.releaseTime {
                let event = buildEvent(endingAt: lastAboveRelease)
                reset()
                return event
            }
            return nil
        }
    }

    /// Closes any in-progress event, e.g. on shutdown.
    ///
    /// - Note: `time` is currently unused — all three branches derive their
    ///   times from internally tracked state (`.recording` closes at
    ///   `lastAboveRelease`; `.idle`/`.candidate` emit nothing). The
    ///   parameter is retained deliberately, not dead code to be removed: it
    ///   preserves the caller-supplies-time contract this detector holds
    ///   everywhere else (it never reads the clock itself), which a later
    ///   milestone may need to rely on again.
    public func finish(at time: TimeInterval) -> DetectedEvent? {
        switch state {
        case .idle:
            return nil
        case .candidate:
            // Never qualified — discard.
            //
            // This is deliberate, not a missed edge case: process() promotes
            // .candidate to .recording the instant
            // `time - eventStart >= minimumDuration`. So a .candidate still
            // lingering when finish() is called necessarily has LESS than
            // minimumDuration of *observed* above-threshold signal — there
            // is no window of samples to report statistics over. Emitting it
            // anyway would mean fabricating a duration nobody measured. For
            // an evidence-gathering tool, inventing duration is worse than
            // silently dropping a marginal, unproven event. Do not "fix"
            // this to emit.
            reset()
            return nil
        case .recording:
            let event = buildEvent(endingAt: lastAboveRelease)
            reset()
            return event
        }
    }

    /// Returns to idle, discarding any in-progress event without emitting it.
    public func reset() {
        state = .idle
        eventStart = 0
        lastAboveRelease = 0
        peak = -.infinity
        levelSum = 0
        levelCount = 0
    }

    // MARK: - Private

    private func beginEvent(level: Double, at time: TimeInterval) {
        eventStart = time
        lastAboveRelease = time
        peak = level
        levelSum = level
        levelCount = 1
    }

    private func accumulate(level: Double, at time: TimeInterval) {
        // Only levels that are part of the event count toward its statistics.
        // Samples below the release threshold are the trailing silence of the
        // release window; including them drags every event's mean toward the
        // floor and makes peak/mean disagree with the reported duration, which
        // already ends at `lastAboveRelease`.
        guard level >= config.releaseDBFS else { return }
        peak = max(peak, level)
        levelSum += level
        levelCount += 1
        lastAboveRelease = time
    }

    private func buildEvent(endingAt end: TimeInterval) -> DetectedEvent {
        DetectedEvent(
            startTime: eventStart,
            duration: max(end - eventStart, 0),
            peakDBFS: peak,
            meanDBFS: levelCount > 0 ? levelSum / Double(levelCount) : peak
        )
    }
}
