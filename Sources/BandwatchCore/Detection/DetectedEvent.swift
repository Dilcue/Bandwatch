import Foundation

public struct DetectedEvent: Equatable, Sendable {
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let peakDBFS: Double
    public let meanDBFS: Double

    public init(startTime: TimeInterval, duration: TimeInterval, peakDBFS: Double, meanDBFS: Double) {
        self.startTime = startTime
        self.duration = duration
        self.peakDBFS = peakDBFS
        self.meanDBFS = meanDBFS
    }
}
