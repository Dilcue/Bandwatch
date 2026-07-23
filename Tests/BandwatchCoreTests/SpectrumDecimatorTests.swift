import Testing
@testable import BandwatchCore

@Suite("decimateForDisplay")
struct SpectrumDecimatorTests {

    @Test("output count never exceeds pixelWidth")
    func neverExceedsPixelWidth() {
        let magnitudes = [Float](repeating: 0.01, count: 4096)
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: 44100.0 / 8192.0,
            minHz: 20.0,
            maxHz: 22050.0,
            pixelWidth: 900
        )
        #expect(result.count <= 900)
        #expect(!result.isEmpty)
    }

    @Test("a narrow peak survives decimation")
    func peakSurvives() {
        // 4096 low-level bins with a single tall spike among low neighbours.
        // A mean- or stride-based reducer would average or skip the spike;
        // a max-based reducer must preserve it exactly.
        var magnitudes = [Float](repeating: 0.001, count: 4096)
        let peakBin = 1200
        let peakMagnitude: Float = 5.0
        magnitudes[peakBin] = peakMagnitude

        let binWidthHz = 44100.0 / 8192.0
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: binWidthHz,
            minHz: 20.0,
            maxHz: 22050.0,
            pixelWidth: 900
        )

        #expect(result.contains { $0.magnitude == peakMagnitude })
    }

    @Test("frequencies outside minHz...maxHz are excluded")
    func excludesOutOfRange() {
        let binWidthHz = 10.0
        // bins 0...409 cover 0...4090 Hz; restrict window to 100...2000 Hz.
        let magnitudes = [Float](repeating: 1.0, count: 410)
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: binWidthHz,
            minHz: 100.0,
            maxHz: 2000.0,
            pixelWidth: 200
        )
        #expect(result.allSatisfy { $0.hz >= 100.0 && $0.hz <= 2000.0 })
    }

    @Test("output is ordered by ascending frequency")
    func orderedAscending() {
        let magnitudes = (0..<4096).map { Float($0 % 17) + 0.1 }
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: 44100.0 / 8192.0,
            minHz: 20.0,
            maxHz: 22050.0,
            pixelWidth: 900
        )
        let hzs = result.map(\.hz)
        #expect(hzs == hzs.sorted())
    }

    @Test("empty magnitudes are safe")
    func emptyMagnitudes() {
        let result = decimateForDisplay(
            magnitudes: [],
            binWidthHz: 10.0,
            minHz: 20.0,
            maxHz: 20000.0,
            pixelWidth: 900
        )
        #expect(result.isEmpty)
    }

    @Test("pixelWidth of zero is safe")
    func zeroPixelWidth() {
        let magnitudes = [Float](repeating: 1.0, count: 4096)
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: 10.0,
            minHz: 20.0,
            maxHz: 20000.0,
            pixelWidth: 0
        )
        #expect(result.isEmpty)
    }

    @Test("pixelWidth of one is safe and returns at most one point")
    func onePixelWidth() {
        let magnitudes = [Float](repeating: 1.0, count: 4096)
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: 10.0,
            minHz: 20.0,
            maxHz: 20000.0,
            pixelWidth: 1
        )
        #expect(result.count <= 1)
    }

    @Test("realistic case: 4096 bins, 20-22050 Hz, 900 px wide")
    func realisticCase() {
        let magnitudes = (0..<4096).map { Float($0 % 23) + 0.05 }
        let result = decimateForDisplay(
            magnitudes: magnitudes,
            binWidthHz: 44100.0 / 8192.0,
            minHz: 20.0,
            maxHz: 22050.0,
            pixelWidth: 900
        )
        #expect(result.count <= 900)
        #expect(!result.isEmpty)
    }
}
