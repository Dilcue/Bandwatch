import AVFoundation
import Foundation

/// Plays a band-filtered event clip. Because clips are band-filtered, very low
/// frequencies may be inaudible on laptop speakers — the UI notes this so a
/// quiet-but-present clip is not mistaken for an empty one.
@MainActor
public final class ClipPlayer {
    private var player: AVAudioPlayer?
    public private(set) var isPlaying = false

    public init() {}

    public func play(url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        isPlaying = true
    }

    public func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
