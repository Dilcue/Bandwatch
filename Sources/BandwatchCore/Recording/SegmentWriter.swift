import Foundation

/// Writes the continuous archive as fixed-length segments.
///
/// Segments bound how much audio is lost if the process dies: a closed segment
/// is complete and readable on disk, whereas an open one is not readable at all
/// (verified: opening a FLAC file whose writer is still alive fails with
/// ExtAudioFileOpenURL error 1718449215). This is the entire reason the
/// archive is segmented rather than written as one continuous file.
///
/// Rollover is driven by frames written, not by comparing wall-clock times —
/// the audio clock determines segment length and cannot jump.
///
/// Not Sendable; used only inside `RecordingCoordinator`.
public final class SegmentWriter {
    public static let defaultSegmentDuration: TimeInterval = 3600

    /// A FLAC file below this length never finalizes into a readable stream,
    /// even with a correct close(). Verified empirically while building
    /// `FLACWriter`. Anything shorter is a stub, not a recording, and must
    /// not be presented as one.
    public static let minimumReadableFrames = 4608

    public private(set) var closedSegmentURLs: [URL] = []
    public var currentURL: URL? { writer?.url }

    /// Segments discarded because they were too short to finalize into a readable
    /// FLAC stream, and the audio lost with them.
    ///
    /// Discarding is correct — a sub-minimum file cannot be opened at all — but it
    /// must not be silent. This app's guarantee is that coverage is verifiable, so
    /// the caller needs to be able to account for every discarded interval.
    public private(set) var discardedStubCount: Int = 0
    public private(set) var discardedFrames: Int = 0

    private let paths: RecordingPaths
    private let sampleRate: Double
    private let framesPerSegment: Int
    private var writer: FLACWriter?

    public init(paths: RecordingPaths, sampleRate: Double,
                segmentDuration: TimeInterval = SegmentWriter.defaultSegmentDuration) {
        precondition(sampleRate > 0)
        precondition(segmentDuration > 0)
        self.paths = paths
        self.sampleRate = sampleRate
        self.framesPerSegment = Int(sampleRate * segmentDuration)
    }

    public func append(_ samples: [Float], wallClock: Date) throws {
        guard !samples.isEmpty else { return }

        if writer == nil {
            writer = try FLACWriter(url: paths.archiveSegmentURL(startingAt: wallClock),
                                    sampleRate: sampleRate)
        }
        guard let w = writer else { return }

        try w.append(samples)

        if w.framesWritten >= framesPerSegment {
            finishCurrent(w)
        }
    }

    /// Closes the in-progress segment so it becomes readable. Idempotent.
    public func closeCurrent() {
        guard let w = writer else { return }
        finishCurrent(w)
    }

    /// Cleans up any in-progress segment when deallocated.
    ///
    /// If a SegmentWriter is deallocated without an explicit closeCurrent(),
    /// this ensures the stub guard still runs: any sub-threshold in-progress
    /// segment is either deleted or listed (and never orphaned on disk).
    deinit {
        guard let w = writer else { return }
        finishCurrent(w)
    }

    /// Closes `w` and either records it as a completed segment or, if it
    /// never reached `minimumReadableFrames`, deletes it instead.
    ///
    /// A rapid stop/start or a rollover landing awkwardly on a very short
    /// remainder can both produce a segment too short to ever finalize into
    /// a readable stream. Such a stub must never appear in
    /// `closedSegmentURLs` — that list is what the rest of the system (and
    /// eventually retention) trusts as the set of recorded segments. This
    /// applies uniformly whether the segment is closed explicitly via
    /// `closeCurrent()` or implicitly by rollover inside `append(_:wallClock:)`.
    private func finishCurrent(_ w: FLACWriter) {
        w.close()
        if w.framesWritten < Self.minimumReadableFrames {
            try? FileManager.default.removeItem(at: w.url)
            discardedStubCount += 1
            discardedFrames += w.framesWritten
        } else {
            closedSegmentURLs.append(w.url)
        }
        writer = nil
    }
}
