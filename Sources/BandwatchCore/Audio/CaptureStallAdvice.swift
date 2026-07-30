import Foundation

/// User-facing copy for the capture-stall banner. Kept out of the view so the
/// message selection is unit-testable, and because the interesting branch — a
/// Multi-Output/Aggregate *system output* device starving input capture — is a
/// documented macOS quirk worth naming precisely, rather than misdirecting the
/// user to a microphone that is working fine.
public enum CaptureStallAdvice {
    /// The banner text shown when capture stalls. `defaultOutputIsAggregate`
    /// comes from `CoreAudioInputDevices.defaultOutputIsAggregate()` at the
    /// moment the banner renders.
    public static func message(defaultOutputIsAggregate: Bool) -> String {
        if defaultOutputIsAggregate {
            return "Monitoring halted — no audio is arriving from the input. Your Mac's " +
                "sound output is set to a Multi-Output Device, which macOS can prevent from " +
                "running alongside input capture. Switch System Settings → Sound → Output to a " +
                "single device, then press Start to resume."
        }
        return "Audio input stopped responding and monitoring has halted. " +
            "Check your microphone/input device, then press Start to resume."
    }
}
