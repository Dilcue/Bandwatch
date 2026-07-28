import Foundation

public struct RetentionPolicy: Equatable, Sendable {
    public var diskFloorBytes: Int64

    /// The free-space level at which `StorageManager.isLowOnDisk()` starts
    /// reporting true -- a warning band ABOVE `diskFloorBytes`, so callers
    /// can alert the user before the floor actually stops recording. `nil`
    /// at init time defaults to `2 * diskFloorBytes` (20 GB against the 10 GB
    /// floor default), computed here rather than as a literal default
    /// argument so a caller who passes a custom `diskFloorBytes` still gets
    /// a proportionate warning band instead of one keyed to the 10 GB
    /// default.
    public var diskWarningBytes: Int64

    public init(diskFloorBytes: Int64 = 10 * 1024 * 1024 * 1024, diskWarningBytes: Int64? = nil) {
        self.diskFloorBytes = diskFloorBytes
        if let diskWarningBytes {
            self.diskWarningBytes = diskWarningBytes
        } else {
            // Saturating, not `diskFloorBytes * 2`: existing tests (and any
            // future caller) construct an "unreachable floor" policy with
            // `diskFloorBytes: Int64.max` to force `isBelowFloor()` true
            // regardless of real free space -- plain multiplication there
            // overflows `Int64` and traps. Clamping to `.max` is also the
            // semantically right answer: an unreachable floor should default
            // to an equally unreachable (not wrapped-negative) warning band.
            let (doubled, overflowed) = diskFloorBytes.multipliedReportingOverflow(by: 2)
            self.diskWarningBytes = overflowed ? Int64.max : doubled
        }
    }
}

/// Disk-space policy. There is no time-based event retention: an evidence
/// tool must never silently delete evidence, so events are kept forever and
/// the only guardrail is the disk-space floor below. When free space drops
/// below `diskFloorBytes` the caller must stop recording and say so — the
/// application never pretends to record, and it never deletes existing
/// evidence to make room.
///
/// The 10 GB floor default is a placeholder from the spec, not derived from a
/// measured MB/hour figure. Real disk consumption under band-filtered audio
/// is not yet known and will be measured during manual verification; do not
/// tune this value against an unverified estimate.
public final class StorageManager {
    public let policy: RetentionPolicy
    private let paths: RecordingPaths

    public init(paths: RecordingPaths, policy: RetentionPolicy = RetentionPolicy()) {
        self.paths = paths
        self.policy = policy
    }

    public func freeBytes() -> Int64? {
        // Walk up from paths.root to find the nearest existing ancestor on the same volume.
        // This ensures we always measure free space on the correct disk, even when the
        // recording root doesn't exist yet (first run) or is an unmounted external drive.
        var probe = paths.root
        while true {
            if FileManager.default.fileExists(atPath: probe.path) {
                let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                return values?.volumeAvailableCapacity.map(Int64.init)
            }
            let parent = probe.deletingLastPathComponent()
            // Guard against infinite loop: if parent equals probe, we've reached the root.
            guard parent != probe else { return nil }
            probe = parent
        }
    }

    public func isBelowFloor() -> Bool {
        // Fail closed: if free space is indeterminate, assume the worst (below floor).
        // This is safe because freeBytes() now always probes an ancestor on the recording
        // volume. An unknown result means something is genuinely wrong (volume gone,
        // permissions broken), not merely that the directory doesn't exist yet.
        // Do not decouple this from the ancestor-probe logic in freeBytes() without
        // reconsidering the failure mode.
        guard let free = freeBytes() else { return true }
        return free < policy.diskFloorBytes
    }

    /// True once free space has dropped into the warning band ABOVE the hard
    /// floor -- the proactive signal a caller alerts the user on, before
    /// `isBelowFloor()` actually stops recording. Same fail-closed contract
    /// as `isBelowFloor()`: an indeterminate free-space reading is treated as
    /// low, not as healthy.
    public func isLowOnDisk() -> Bool {
        guard let free = freeBytes() else { return true }
        return free < policy.diskWarningBytes
    }
}
