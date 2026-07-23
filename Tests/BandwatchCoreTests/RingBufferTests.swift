import Testing
@testable import BandwatchCore

@Test func testWriteThenReadReturnsSamplesOldestFirst() {
    let buf = RingBuffer(capacity: 8)
    var input: [Float] = [1, 2, 3, 4]
    input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 4) }
    #expect(buf.latest(4) == [1, 2, 3, 4])
}

@Test func testReadingMoreThanWrittenReturnsOnlyWhatExists() {
    let buf = RingBuffer(capacity: 8)
    var input: [Float] = [1, 2, 3]
    input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 3) }
    #expect(buf.latest(8) == [1, 2, 3])
}

@Test func testWraparoundKeepsMostRecentSamples() {
    let buf = RingBuffer(capacity: 4)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 6) }
    // Capacity 4, wrote 6 -> oldest two evicted.
    #expect(buf.latest(4) == [3, 4, 5, 6])
}

@Test func testWriteLargerThanCapacityKeepsTail() {
    let buf = RingBuffer(capacity: 3)
    var input: [Float] = [1, 2, 3, 4, 5]
    input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 5) }
    #expect(buf.latest(3) == [3, 4, 5])
}

@Test func testTotalWrittenAccumulatesAcrossWrites() {
    let buf = RingBuffer(capacity: 4)
    var a: [Float] = [1, 2]
    var b: [Float] = [3, 4, 5]
    a.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 2) }
    b.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 3) }
    #expect(buf.totalWritten == 5)
}

@Test func testEmptyBufferReturnsEmpty() {
    let buf = RingBuffer(capacity: 4)
    #expect(buf.latest(4).isEmpty)
}

@Test func testClearResetsStorageWriteIndexAndTotalWritten() {
    let buf = RingBuffer(capacity: 4)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    input.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 6) }
    #expect(buf.totalWritten == 6)

    buf.clear()

    #expect(buf.totalWritten == 0)
    #expect(buf.latest(4).isEmpty)

    // Confirm storage itself was zeroed and the write cursor reset to the
    // start, not just that totalWritten reports 0: write fewer samples than
    // capacity and check what's returned is exactly the new data, not stale
    // leftovers from before the clear at unwritten positions.
    var after: [Float] = [9, 9]
    after.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 2) }
    #expect(buf.latest(4) == [9, 9])
}

@Test func testPartialReadWithNonzeroWriteIndexAndNoWraparound() {
    // Multiple sequential writes leaving writeIndex non-zero, then a partial
    // read that stays within positive modulo arithmetic (start index here is
    // 2, never negative) — i.e. this does NOT exercise the negative-modulo
    // normalization branch in latest(); that path is covered separately by
    // testPartialReadAfterWraparoundCrossingPhysicalEnd below.
    let buf = RingBuffer(capacity: 8)

    // Write 3 samples (writeIndex will be 3)
    var write1: [Float] = [1, 2, 3]
    write1.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 3) }

    // Write 2 more samples (writeIndex will be 5)
    var write2: [Float] = [4, 5]
    write2.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 2) }

    // Read last 3 samples (partial read, fewer than available)
    let result = buf.latest(3)
    #expect(result == [3, 4, 5], "Expected oldest-first order: [\(result)]")
}

@Test func testWraparoundFromMultipleSmallWritesWithFullRead() {
    // Wraparound produced by several small writes (not one large write).
    // After wraparound, read full capacity.
    let buf = RingBuffer(capacity: 4)

    // Write 2 samples (writeIndex = 2)
    var w1: [Float] = [1, 2]
    w1.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 2) }

    // Write 2 more samples (writeIndex = 0, wraps)
    var w2: [Float] = [3, 4]
    w2.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 2) }

    // Write 1 more sample (writeIndex = 1)
    var w3: [Float] = [5]
    w3.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 1) }

    // Write 1 more sample (writeIndex = 2)
    var w4: [Float] = [6]
    w4.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 1) }

    // Now buffer contains [5, 6, 3, 4] physically, with writeIndex = 2
    // latest(4) should return [3, 4, 5, 6]
    let result = buf.latest(4)
    #expect(result == [3, 4, 5, 6], "Expected [\(result)]")
}

@Test func testPartialReadAfterWraparoundCrossingPhysicalEnd() {
    // Partial read after wraparound where start + n crosses the physical end of storage.
    let buf = RingBuffer(capacity: 5)

    // Write 3 samples (writeIndex = 3)
    var w1: [Float] = [1, 2, 3]
    w1.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 3) }

    // Write 3 more samples (writeIndex = 1, wraps around)
    var w2: [Float] = [4, 5, 6]
    w2.withUnsafeBufferPointer { buf.write($0.baseAddress!, count: 3) }

    // Storage is now physically [6, 2, 3, 4, 5] with writeIndex = 1: the
    // second write wrapped past the physical end, overwriting index 0 last.
    // latest(3)'s start index is ((1-3) % 5 + 5) % 5 = 3 — this is the
    // negative-modulo normalization branch, since (1-3) % 5 is -2 in Swift,
    // not 3. Reading 3 samples from index 3 (wrapping through the physical
    // end) gives the 3 most recent: [4, 5, 6].
    let result = buf.latest(3)
    #expect(result == [4, 5, 6], "Expected [\(result)]")
}
