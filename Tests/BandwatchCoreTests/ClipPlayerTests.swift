import Testing
import Foundation
@testable import BandwatchCore

@MainActor @Test func testPlayerStartsNotPlaying() {
    #expect(ClipPlayer().isPlaying == false)
}
@MainActor @Test func testStopWhenNotPlayingIsSafe() {
    let p = ClipPlayer(); p.stop(); #expect(p.isPlaying == false)
}
@MainActor @Test func testPlayMissingFileDoesNotCrashAndStaysStopped() {
    let p = ClipPlayer()
    p.play(url: URL(fileURLWithPath: "/no/such/clip.flac"))
    #expect(p.isPlaying == false)
}
