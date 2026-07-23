import Foundation

/// IEC 61672-style exponential time weighting: "Fast" (125 ms) reacts quickly
/// enough to catch short thumps; "Slow" (1 s) trades responsiveness for
/// steadier plateaus on sustained drones. This only selects the ATTACK time
/// constant -- see `LevelSmoother`'s doc comment for why release is handled
/// separately and is not user-selectable.
public enum TimeWeighting: String, CaseIterable, Equatable, Sendable {
    case fast
    case slow

    /// The exponential time constant, in seconds, per IEC 61672.
    public var timeConstant: TimeInterval {
        switch self {
        case .fast: return 0.125
        case .slow: return 1.0
        }
    }

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .slow: return "Slow"
        }
    }
}

/// Applies exponential time weighting to a stream of per-frame band levels
/// (dBFS), one call to `smooth(_:)` per FFT hop.
///
/// ## Why this smooths in the linear power domain, not in dB
///
/// IEC 61672-style time weighting is exponential averaging applied to
/// *squared sound pressure* — i.e. power — not to the decibel level derived
/// from it. Averaging dBFS values directly is a different operation, and it
/// is the wrong one: dB is a logarithmic compression of power, so a dB-domain
/// average systematically under-weights short loud excursions relative to
/// the true power average. A meter built that way would be too sluggish to
/// register a brief loud burst and too generous toward quiet stretches —
/// precisely backwards from what this integration is supposed to do, and it
/// would not match any real sound level meter's behavior.
///
/// So every sample here is: convert incoming dBFS to linear amplitude, square
/// it to get power, exponentially smooth the power, then convert the smoothed
/// power back to dBFS. Do not "simplify" this into smoothing `dbfs` in place —
/// it would silently change the meter's dynamic behavior in a way that no
/// dB-level spot check would catch, only a step-response test would.
///
/// ## Why attack and release use different time constants
///
/// Exponential power-domain averaging decays at a fixed 4.34 dB per time
/// constant (10 * log10(e) ≈ 4.34) -- symmetrically, by construction, in
/// both directions: the same time constant that governs how quickly the
/// running value climbs onto a new level also governs how quickly it falls
/// back off it. That symmetry is fine, even desirable, on the way up: a
/// longer time constant ("Slow") genuinely reads better for steady plateaus
/// and rising noises, which is why it stays user-selectable via `weighting`.
///
/// But it is actively harmful on the way down. At τ = 1 s ("Slow"), that
/// fixed 4.34 dB/time-constant rate works out to only ~4.34 dB/s of decay,
/// so a 30 dB event takes ~7 seconds to fall below the detector's release
/// threshold — badly inflating measured event durations and merging distinct
/// noises into one continuous event. Whether an event releases promptly is
/// governed entirely by the DECAY rate, not the attack rate, so this
/// smoother pins release at the Fast time constant (`releaseTimeConstant`,
/// 0.125 s) unconditionally, while attack remains whatever `weighting`
/// selects. When Fast is selected the two coincide and behaviour is
/// unchanged from a single-constant smoother; when Slow is selected, only
/// the rise is more gradual -- the fall is exactly as prompt as Fast's.
public final class LevelSmoother {
    /// The release (decay) time constant, in seconds. Fixed, not
    /// user-selectable: this is what determines whether a finished noise
    /// falls below the detector's release threshold promptly, and IEC
    /// "Slow" (1 s) release is exactly what caused the ~7 second
    /// event-duration inflation this fixed constant avoids.
    public static let releaseTimeConstant: TimeInterval = 0.125

    /// Selects the ATTACK time constant only (used when incoming power is
    /// greater than the current running value, in the linear power domain).
    /// Changing this recomputes the attack coefficient (`attackAlpha`) but
    /// does NOT reset the running value — it's a response-speed preference,
    /// not a re-tuning of what's being measured. Release always uses
    /// `Self.releaseTimeConstant`, regardless of this setting.
    public var weighting: TimeWeighting {
        didSet {
            guard weighting != oldValue else { return }
            recomputeAttackAlpha()
        }
    }

    private let hopInterval: TimeInterval
    private var attackAlpha: Double
    private let releaseAlpha: Double

    /// The exponentially smoothed power (linear domain, not dB). `nil` means
    /// "uninitialised" — the next `smooth(_:)` call will initialise it
    /// directly from its input rather than ramping up from zero.
    private var runningPower: Double?

    public init(weighting: TimeWeighting, hopInterval: TimeInterval) {
        precondition(hopInterval > 0, "hopInterval must be > 0")
        self.weighting = weighting
        self.hopInterval = hopInterval
        self.attackAlpha = Self.computeAlpha(timeConstant: weighting.timeConstant, hopInterval: hopInterval)
        self.releaseAlpha = Self.computeAlpha(timeConstant: Self.releaseTimeConstant, hopInterval: hopInterval)
    }

    private static func computeAlpha(timeConstant: TimeInterval, hopInterval: TimeInterval) -> Double {
        1 - exp(-hopInterval / timeConstant)
    }

    private func recomputeAttackAlpha() {
        attackAlpha = Self.computeAlpha(timeConstant: weighting.timeConstant, hopInterval: hopInterval)
    }

    /// Feeds one raw dBFS level and returns the time-weighted (smoothed)
    /// dBFS level.
    public func smooth(_ dbfs: Double) -> Double {
        let amplitude = pow(10.0, dbfs / 20.0)
        let power = amplitude * amplitude

        let smoothedPower: Double
        if let runningPower {
            // Standard first-order exponential (IIR) smoother:
            // y[n] = y[n-1] + alpha * (x[n] - y[n-1])
            //
            // Which alpha applies is decided by comparing in the LINEAR
            // POWER domain -- that's where `runningPower` actually lives --
            // not in dB: incoming power greater than the running value is an
            // attack (use the user-selected weighting's constant); incoming
            // power less than or equal to the running value is a release
            // (always use the fixed, fast release constant).
            let alpha = power > runningPower ? attackAlpha : releaseAlpha
            smoothedPower = runningPower + alpha * (power - runningPower)
        } else {
            // First sample after construction/reset(): initialise directly
            // rather than ramping up from zero, otherwise every session would
            // show a spurious rise from silence regardless of the true
            // starting level.
            smoothedPower = power
        }
        self.runningPower = smoothedPower

        guard smoothedPower > 0, smoothedPower.isFinite else {
            return BandLevelMeter.silenceFloorDBFS
        }
        let dbOut = 10.0 * log10(smoothedPower)
        return max(dbOut, BandLevelMeter.silenceFloorDBFS)
    }

    /// Returns the smoother to its uninitialised state: the next `smooth(_:)`
    /// call will initialise directly from its input instead of continuing
    /// from the discarded running value.
    public func reset() {
        runningPower = nil
    }
}
