import Testing
import Foundation
import AVFoundation
@testable import BandwatchCore

private func tempPaths() -> RecordingPaths {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("bwseg-\(UUID().uuidString)")
    return RecordingPaths(root: d)
}

private func block(_ n: Int) -> [Float] { [Float](repeating: 0.1, count: n) }

@Test func testWritesToASingleSegmentBelowDuration() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 100, segmentDuration: 10)  // 1000 frames/segment
    try w.append(block(300), wallClock: Date())
    try w.append(block(300), wallClock: Date())
    #expect(w.closedSegmentURLs.isEmpty)
    #expect(w.currentURL != nil)
    w.closeCurrent()
}

// Rescaled from the brief's original (sampleRate: 100, segmentDuration: 10,
// blocks of 600). With those numbers the segment that rolls over would have
// written only 1200 frames total — below SegmentWriter.minimumReadableFrames
// (4608) — so under the new stub guard it would be deleted rather than
// appended to closedSegmentURLs, and `closedSegmentURLs.count == 1` would
// fail. Scaled sampleRate/duration/blocks by 10x (framesPerSegment 1000 ->
// 4500, blocks 600 -> 3000) so the rolled-over segment (6000 frames) clears
// the threshold and the rollover behavior under test is still observable.
@Test func testRollsOverWhenSegmentFills() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 100, segmentDuration: 45)  // 4500 frames/segment
    let first = try { () -> URL in
        try w.append(block(3000), wallClock: Date())
        return w.currentURL!
    }()
    try w.append(block(3000), wallClock: Date().addingTimeInterval(6))
    #expect(w.closedSegmentURLs.count == 1)
    #expect(w.closedSegmentURLs[0] == first)
    #expect(w.currentURL != first)
    w.closeCurrent()
}

@Test func testClosedSegmentsAreReadable() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 44100, segmentDuration: 1)  // 44100 frames
    try w.append(block(30000), wallClock: Date())
    try w.append(block(30000), wallClock: Date().addingTimeInterval(1))
    w.closeCurrent()
    // A closed segment must be openable — this is why segments exist.
    for url in w.closedSegmentURLs {
        let f = try AVAudioFile(forReading: url)
        #expect(f.length > 0)
    }
}

// Rewritten from the brief's original (sampleRate: 100, segmentDuration: 1 ->
// 100 frames/segment, blocks of 100). There, each append's block size
// exactly equaled framesPerSegment, so every segment opened and immediately
// rolled over within the *same* append() call: currentURL was nil
// immediately after every call, and `seen` could never collect a single URL,
// let alone 4 distinct ones — the test's intent (observing distinct segment
// file names across rollovers) could never be satisfied as written.
// Rescaled so a segment accumulates across two appends before rolling over,
// giving currentURL a chance to be read while a segment is still open, and
// extended the loop to 8 iterations so 4 segments are actually opened and
// observed. Sized above SegmentWriter.minimumReadableFrames (4608) too, so
// the segments that do roll over (6000 frames each) are real, non-stub
// segments rather than being silently deleted by the stub guard.
@Test func testSegmentsUseDistinctFileNames() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 100, segmentDuration: 45)  // 4500 frames/segment
    var seen = Set<URL>()
    var t = Date()
    for _ in 0..<8 {
        try w.append(block(3000), wallClock: t)
        if let u = w.currentURL { seen.insert(u) }
        t = t.addingTimeInterval(1)
    }
    w.closeCurrent()
    #expect(seen.count >= 4)
}

@Test func testCloseCurrentIsIdempotent() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 100, segmentDuration: 10)
    try w.append(block(100), wallClock: Date())
    w.closeCurrent()
    w.closeCurrent()
    #expect(w.currentURL == nil)
}

@Test func testAppendAfterCloseStartsANewSegment() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 100, segmentDuration: 10)
    try w.append(block(100), wallClock: Date())
    let first = w.currentURL
    w.closeCurrent()
    try w.append(block(100), wallClock: Date().addingTimeInterval(2))
    #expect(w.currentURL != nil)
    #expect(w.currentURL != first)
    w.closeCurrent()
}

// MARK: - Minimum readable length guard

@Test func testStubSegmentBelowMinimumReadableFramesIsDeletedOnClose() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 44100, segmentDuration: 3600)
    try w.append(block(SegmentWriter.minimumReadableFrames - 1), wallClock: Date())
    let url = try #require(w.currentURL)
    w.closeCurrent()
    #expect(w.closedSegmentURLs.isEmpty)
    #expect(w.currentURL == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func testSegmentAtOrAboveMinimumReadableFramesIsKeptAndReadable() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 44100, segmentDuration: 3600)
    try w.append(block(SegmentWriter.minimumReadableFrames + 1000), wallClock: Date())
    w.closeCurrent()
    #expect(w.closedSegmentURLs.count == 1)
    let url = try #require(w.closedSegmentURLs.first)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let f = try AVAudioFile(forReading: url)
    #expect(f.length > 0)
}

@Test func testDiscardedStubCountAndFramesAreTracked() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 44100, segmentDuration: 3600)
    #expect(w.discardedStubCount == 0)
    #expect(w.discardedFrames == 0)

    let frameCount = SegmentWriter.minimumReadableFrames - 1
    try w.append(block(frameCount), wallClock: Date())
    w.closeCurrent()

    #expect(w.discardedStubCount == 1)
    #expect(w.discardedFrames == frameCount)
}

@Test func testNormalSegmentLeavesDiscardCountersAtZero() throws {
    let p = tempPaths()
    let w = SegmentWriter(paths: p, sampleRate: 44100, segmentDuration: 3600)
    try w.append(block(SegmentWriter.minimumReadableFrames + 1000), wallClock: Date())
    w.closeCurrent()

    #expect(w.discardedStubCount == 0)
    #expect(w.discardedFrames == 0)
    #expect(w.closedSegmentURLs.count == 1)
}
