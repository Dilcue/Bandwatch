import Foundation

/// A validated frequency range in hertz.
public struct FrequencyBand: Equatable, Sendable, Codable {
    public let lowHz: Double
    public let highHz: Double

    public init?(lowHz: Double, highHz: Double) {
        guard lowHz > 0, highHz > lowHz else { return nil }
        self.lowHz = lowHz
        self.highHz = highHz
    }

    /// Geometric mean — the perceptually correct center for a log-scaled axis.
    public var centerHz: Double { (lowHz * highHz).squareRoot() }

    public func contains(_ hz: Double) -> Bool {
        hz >= lowHz && hz <= highHz
    }

    /// The frequency range that carries intelligible speech — the standard voice
    /// band, ~300 Hz–3.4 kHz. Bands below it (a subwoofer's bass) can't reproduce
    /// understandable words; bands overlapping it can.
    public static let speechLowHz = 300.0
    public static let speechHighHz = 3400.0

    /// Whether this band overlaps the speech-intelligibility range, meaning
    /// band-filtered clips could contain understandable conversation. Used to
    /// warn before recordings in higher bands are exported/shared.
    public var overlapsSpeechRange: Bool {
        highHz > Self.speechLowHz && lowHz < Self.speechHighHz
    }

    public static let bassSubwoofer = FrequencyBand(lowHz: 20, highHz: 120)!
    public static let applianceWhine = FrequencyBand(lowHz: 2000, highHz: 8000)!
    public static let beeping = FrequencyBand(lowHz: 1000, highHz: 4000)!
}
