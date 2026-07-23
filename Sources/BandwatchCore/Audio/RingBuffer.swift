import Foundation

/// Fixed-capacity circular sample buffer.
///
/// `write` is safe to call from the realtime audio thread: it does not allocate.
/// It takes an `NSLock` to protect the buffer; this is a deliberate compromise for
/// a single-writer/single-reader buffer with a very short critical section. On Darwin,
/// an uncontended `NSLock` does not syscall in the fast path. Whether to replace the
/// lock with an atomic index is an open question scheduled for measurement.
/// `latest` allocates and must only be called from a non-realtime context (the
/// processing queue).
public final class RingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let lock = NSLock()
    private var writeIndex = 0
    private var written = 0

    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    public var totalWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        // If the incoming block exceeds capacity, only its tail can survive.
        let offset = count > capacity ? count - capacity : 0
        let n = count - offset

        lock.lock()
        defer { lock.unlock() }

        for i in 0..<n {
            storage[(writeIndex + i) % capacity] = samples[offset + i]
        }
        writeIndex = (writeIndex + n) % capacity
        written += count
    }

    /// Zeroes storage and resets both the write cursor and `totalWritten` to 0.
    ///
    /// Callers restarting capture after a `stop()` must call this before the
    /// next `start()`: without it, the first post-restart analysis window
    /// would splice pre-gap and post-gap audio across a discontinuity,
    /// producing broadband splatter that can spuriously trip the detector.
    /// Resetting `totalWritten` to 0 also means the staleness/stall check in
    /// `MonitoringSession` starts from a known-good baseline across restarts,
    /// rather than comparing against a stale high-water mark from before the
    /// gap.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<storage.count {
            storage[i] = 0
        }
        writeIndex = 0
        written = 0
    }

    public func latest(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(written, capacity)
        let n = min(count, available)
        guard n > 0 else { return [] }

        var out = [Float](repeating: 0, count: n)
        // writeIndex points one past the newest sample.
        let start = ((writeIndex - n) % capacity + capacity) % capacity
        for i in 0..<n {
            out[i] = storage[(start + i) % capacity]
        }
        return out
    }
}
