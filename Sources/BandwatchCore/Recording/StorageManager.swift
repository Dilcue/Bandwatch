import Foundation

public struct RetentionPolicy: Equatable, Sendable {
    public var diskFloorBytes: Int64

    public init(diskFloorBytes: Int64 = 10 * 1024 * 1024 * 1024) {
        self.diskFloorBytes = diskFloorBytes
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
}
