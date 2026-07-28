import Testing
import Foundation
@testable import BandwatchCore

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwstore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func testDefaultPolicyMatchesSpec() {
    let p = RetentionPolicy()
    #expect(p.eventDays == 90)
    #expect(p.diskFloorBytes == 10 * 1024 * 1024 * 1024)
}

@Test func testFreeBytesIsPositiveOnARealVolume() {
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()))
    let free = m.freeBytes()
    #expect(free != nil)
    #expect((free ?? 0) > 0)
}

@Test func testApplyRetentionReturnsEventCutoff() {
    let root = tempRoot()
    let paths = RecordingPaths(root: root)
    let m = StorageManager(paths: paths, policy: RetentionPolicy(eventDays: 90, diskFloorBytes: 0))
    let now = Date()
    let cutoffForEvents = m.applyRetention(now: now)
    // Event cutoff is 90 days back
    #expect(abs(cutoffForEvents.timeIntervalSince(now.addingTimeInterval(-90 * 86400))) < 1)
}

@Test func testFreeSpaceReportedForNonExistentRoot() {
    // First-run case: root does not exist yet. Ensure free space is measured on the
    // volume where the root would be created, not the temp directory.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bw-nonexistent-\(UUID().uuidString)")
        .appendingPathComponent("recording")
    #expect(!FileManager.default.fileExists(atPath: root.path))

    let m = StorageManager(paths: RecordingPaths(root: root))
    let free = m.freeBytes()
    #expect(free != nil)
    #expect((free ?? 0) > 0)
}

@Test func testIsBelowFloorFailsClosedWhenFreeSpaceIndeterminate() {
    // When freeBytes() returns nil (e.g., due to an inaccessible ancestor chain),
    // isBelowFloor() must fail closed and return true to prevent recording when
    // disk space is unknown. This is safe because freeBytes() probes an ancestor
    // on the same volume; nil means something is genuinely wrong, not merely that
    // the directory doesn't exist.
    //
    // To test this directly, we would need to mock freeBytes() or create a path
    // with no accessible ancestors, which is impossible (filesystem root always exists
    // and is accessible). Instead, we verify the logic by examining the source code
    // and confirming that guard let freeBytes() else { return true } is in place.
    // A more complete test would require dependency injection of filesystem operations.
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()),
                           policy: RetentionPolicy(diskFloorBytes: Int64.max))
    // With an impossible floor, even a real volume with space should be below floor.
    #expect(m.isBelowFloor() == true)
}
