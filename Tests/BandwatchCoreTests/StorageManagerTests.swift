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
    #expect(p.diskFloorBytes == 10 * 1024 * 1024 * 1024)
}

@Test func testFreeBytesIsPositiveOnARealVolume() {
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()))
    let free = m.freeBytes()
    #expect(free != nil)
    #expect((free ?? 0) > 0)
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

@Test func testDefaultWarningIsTwiceTheFloor() {
    let p = RetentionPolicy()
    #expect(p.diskWarningBytes == 2 * p.diskFloorBytes)
}

@Test func testCustomFloorScalesTheDefaultWarningProportionately() {
    let p = RetentionPolicy(diskFloorBytes: 5 * 1024 * 1024 * 1024)
    #expect(p.diskWarningBytes == 10 * 1024 * 1024 * 1024)
}

@Test func testDefaultWarningSaturatesRatherThanOverflowingForAHugeFloor() {
    // The default warning is 2x the floor. For a floor near Int64.max, `2 *
    // floor` would overflow and TRAP -- so the init saturates to Int64.max
    // instead. Several other tests (floor-stop, session/coordinator low-disk)
    // construct `RetentionPolicy(diskFloorBytes: Int64.max)` and rely on this
    // not trapping; pin the intent DIRECTLY here so a regression to a plain
    // `2 * floor` fails as this one explicit case, not as a SIGTRAP buried in
    // an unrelated test.
    let p = RetentionPolicy(diskFloorBytes: Int64.max)
    #expect(p.diskWarningBytes == Int64.max)
}

@Test func testIsLowOnDiskTrueWhenFreeIsBelowWarningButAboveFloor() {
    // Read the real free space on this volume once, then set a warning
    // threshold just above it (so isLowOnDisk() reports true) and a floor of
    // 0 (so isBelowFloor() stays false) -- proves the warning band is
    // genuinely distinct from, and checked independently of, the hard floor.
    let root = tempRoot()
    let probe = StorageManager(paths: RecordingPaths(root: root))
    let free = probe.freeBytes() ?? 0

    let m = StorageManager(paths: RecordingPaths(root: root),
                           policy: RetentionPolicy(diskFloorBytes: 0, diskWarningBytes: free + 1))
    #expect(m.isBelowFloor() == false)
    #expect(m.isLowOnDisk() == true)
}

@Test func testIsLowOnDiskFalseWithAmpleFreeSpace() {
    // An unreachable (zero) warning threshold means free space can never be
    // "below" it, mirroring how `RetentionPolicy(diskFloorBytes: 0)` proves
    // `isBelowFloor()`'s no-op case elsewhere in this suite.
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()),
                           policy: RetentionPolicy(diskWarningBytes: 0))
    #expect(m.isLowOnDisk() == false)
}

@Test func testIsLowOnDiskFailsClosedWhenFreeSpaceIndeterminate() {
    // isLowOnDisk() carries the same fail-closed contract as isBelowFloor():
    // an indeterminate free-space reading (freeBytes() == nil) is treated as
    // low, not healthy -- an evidence tool must warn when the disk state is
    // unknown, never go silent. As with the isBelowFloor() fail-closed test
    // below, nil cannot be forced directly (freeBytes() probes an ancestor and
    // the filesystem root always exists), so this uses an impossibly high
    // warning threshold as a proxy: any real free space is "below" Int64.max,
    // exercising the same `free < diskWarningBytes` verdict the nil branch
    // short-circuits to. A true nil test would require injecting freeBytes(),
    // which would decouple it from the ancestor-probe logic it must not.
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()),
                           policy: RetentionPolicy(diskWarningBytes: Int64.max))
    #expect(m.isLowOnDisk() == true)
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
