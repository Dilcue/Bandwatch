import Foundation

public struct DetectorConfig: Equatable, Sendable {
    public var triggerDBFS: Double
    public var releaseOffsetDB: Double
    public var minimumDuration: TimeInterval
    public var releaseTime: TimeInterval
    public var maximumDuration: TimeInterval

    public init(
        triggerDBFS: Double,
        releaseOffsetDB: Double = 6.0,
        minimumDuration: TimeInterval = 1.5,
        releaseTime: TimeInterval = 3.0,
        maximumDuration: TimeInterval = 300.0
    ) {
        precondition(minimumDuration >= 0, "minimumDuration must be >= 0, got \(minimumDuration)")
        precondition(releaseTime >= 0, "releaseTime must be >= 0, got \(releaseTime)")
        precondition(maximumDuration > 0, "maximumDuration must be > 0, got \(maximumDuration)")
        precondition(
            maximumDuration >= minimumDuration,
            "maximumDuration (\(maximumDuration)) must be >= minimumDuration (\(minimumDuration))"
        )
        precondition(releaseOffsetDB >= 0, "releaseOffsetDB must be >= 0, got \(releaseOffsetDB)")

        self.triggerDBFS = triggerDBFS
        self.releaseOffsetDB = releaseOffsetDB
        self.minimumDuration = minimumDuration
        self.releaseTime = releaseTime
        self.maximumDuration = maximumDuration
    }

    /// Hysteresis floor: the level must fall below this to begin releasing.
    public var releaseDBFS: Double { triggerDBFS - releaseOffsetDB }
}
