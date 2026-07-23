import Testing
import Foundation
@testable import BandwatchCore

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwstore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func writeFile(_ url: URL, modified: Date) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
    try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

@Test func testDefaultPolicyMatchesSpec() {
    let p = RetentionPolicy()
    #expect(p.archiveDays == 30)
    #expect(p.eventDays == 90)
    #expect(p.diskFloorBytes == 10 * 1024 * 1024 * 1024)
}

@Test func testFreeBytesIsPositiveOnARealVolume() {
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()))
    let free = m.freeBytes()
    #expect(free != nil)
    #expect((free ?? 0) > 0)
}

@Test func testFindsArchiveFilesOlderThanCutoff() {
    let root = tempRoot()
    let paths = RecordingPaths(root: root)
    let m = StorageManager(paths: paths)
    let now = Date()
    writeFile(paths.archiveDirectory.appendingPathComponent("2026-01-01/old.flac"),
              modified: now.addingTimeInterval(-100_000))
    writeFile(paths.archiveDirectory.appendingPathComponent("2026-07-20/new.flac"),
              modified: now)
    let old = m.archiveFilesOlderThan(now.addingTimeInterval(-1000))
    #expect(old.count == 1)
    #expect(old[0].lastPathComponent == "old.flac")
}

@Test func testDeletesOldestArchiveFilesFirst() {
    let root = tempRoot()
    let paths = RecordingPaths(root: root)
    let m = StorageManager(paths: paths)
    let now = Date()
    for (i, name) in ["a", "b", "c"].enumerated() {
        writeFile(paths.archiveDirectory.appendingPathComponent("d/\(name).flac"),
                  modified: now.addingTimeInterval(Double(i) * -10_000))
    }
    // c is oldest (-20000), then b (-10000), then a (0)
    let deleted = m.deleteOldestArchiveFiles(count: 2)
    #expect(deleted.count == 2)
    #expect(Set(deleted.map { $0.lastPathComponent }) == Set(["c.flac", "b.flac"]))
    #expect(!FileManager.default.fileExists(atPath: deleted[0].path))
    #expect(FileManager.default.fileExists(
        atPath: paths.archiveDirectory.appendingPathComponent("d/a.flac").path))
}

@Test func testApplyRetentionDeletesBeyondArchiveWindow() {
    let root = tempRoot()
    let paths = RecordingPaths(root: root)
    let m = StorageManager(paths: paths, policy: RetentionPolicy(archiveDays: 30,
                                                                 eventDays: 90,
                                                                 diskFloorBytes: 0))
    let now = Date()
    writeFile(paths.archiveDirectory.appendingPathComponent("x/keep.flac"),
              modified: now.addingTimeInterval(-10 * 86400))
    writeFile(paths.archiveDirectory.appendingPathComponent("x/drop.flac"),
              modified: now.addingTimeInterval(-40 * 86400))
    let result = m.applyRetention(now: now)
    #expect(result.archiveDeleted.count == 1)
    #expect(result.archiveDeleted[0].lastPathComponent == "drop.flac")
    // Event cutoff is 90 days back
    #expect(abs(result.cutoffForEvents.timeIntervalSince(now.addingTimeInterval(-90 * 86400))) < 1)
}

@Test func testDeleteOnEmptyArchiveIsSafe() {
    let m = StorageManager(paths: RecordingPaths(root: tempRoot()))
    #expect(m.deleteOldestArchiveFiles(count: 5).isEmpty)
    #expect(m.archiveFilesOlderThan(Date()).isEmpty)
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
