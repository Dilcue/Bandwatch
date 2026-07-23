import Foundation

/// One analysis window's result: the spectrum and the in-band level.
public struct AnalysisFrame: Sendable {
    public let magnitudes: [Float]
    public let bandLevelDBFS: Double
    public let timestamp: TimeInterval

    public init(magnitudes: [Float], bandLevelDBFS: Double, timestamp: TimeInterval) {
        self.magnitudes = magnitudes
        self.bandLevelDBFS = bandLevelDBFS
        self.timestamp = timestamp
    }
}
