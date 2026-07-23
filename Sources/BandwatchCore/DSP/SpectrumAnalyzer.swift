import Accelerate
import Foundation

/// Windowed real FFT producing magnitude bins.
///
/// Not thread-safe: it owns mutable scratch buffers. Use one instance per
/// processing queue.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var binCount: Int { fftSize / 2 }
    public var binWidthHz: Double { sampleRate / Double(fftSize) }

    /// Noise power bandwidth of the analysis window, in bins.
    ///
    /// Summing squared magnitudes across a window's main lobe over-counts power by
    /// this factor. Consumers computing absolute levels must divide it out.
    /// Derived from the actual window coefficients, so it stays correct if the
    /// window type ever changes. Equals exactly 1.5 for a Hann window.
    public let windowNoisePowerBandwidth: Double

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var input: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var magnitudes: [Float]

    public init?(fftSize: Int, sampleRate: Double) {
        guard fftSize > 1, (fftSize & (fftSize - 1)) == 0 else { return nil }
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return nil
        }
        self.fft = fft
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.window = vDSP.window(ofType: Float.self,
                                  usingSequence: .hanningDenormalized,
                                  count: fftSize,
                                  isHalfWindow: false)

        // Compute noise power bandwidth from the actual window coefficients.
        // NPBW_bins = N * sum(w[i]^2) / (sum(w[i]))^2
        var sumWeights: Double = 0.0
        var sumSquares: Double = 0.0
        for coeff in self.window {
            let w = Double(coeff)
            sumWeights += w
            sumSquares += w * w
        }
        self.windowNoisePowerBandwidth = Double(fftSize) * sumSquares / (sumWeights * sumWeights)

        self.input = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.real = [Float](repeating: 0, count: fftSize / 2)
        self.imag = [Float](repeating: 0, count: fftSize / 2)
        self.outReal = [Float](repeating: 0, count: fftSize / 2)
        self.outImag = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    public func frequency(ofBin bin: Int) -> Double {
        Double(bin) * binWidthHz
    }

    public func binIndex(forFrequency hz: Double) -> Int {
        let idx = Int((hz / binWidthHz).rounded())
        return min(max(idx, 0), binCount - 1)
    }

    public func analyze(_ samples: [Float]) -> [Float] {
        // Zero-pad or truncate to exactly fftSize. `input` is a reused scratch
        // buffer, so it must be fully re-zeroed each call: otherwise samples
        // left over from a previous, longer call would leak into the
        // zero-padding region of a later, shorter call.
        for i in 0..<fftSize { input[i] = 0 }
        let n = min(samples.count, fftSize)
        if n > 0 { input.replaceSubrange(0..<n, with: samples[0..<n]) }

        vDSP.multiply(input, window, result: &windowed)

        windowed.withUnsafeMutableBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))

                        outReal.withUnsafeMutableBufferPointer { orp in
                            outImag.withUnsafeMutableBufferPointer { oip in
                                var out = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                                fft.forward(input: split, output: &out)
                                vDSP_zvabs(&out, 1, &magnitudes, 1, vDSP_Length(binCount))
                            }
                        }
                    }
                }
            }
        }

        // Normalize: scale by 2/fftSize so that the peak bin magnitude equals
        // the amplitude of a sine at that bin's centre frequency. A full-scale
        // sine (amplitude 1.0) reads as magnitude 1.0. This convention works
        // because vDSP's real-FFT returns 2× the mathematical DFT, and the
        // Hann window's coherent gain is 0.5; together they cancel to give
        // exactly the sine's amplitude. Do not alter this constant—it changes
        // every dBFS level the app reports.
        // Note: assign the result rather than passing `result: &magnitudes` —
        // aliasing the input and output of a vDSP call is not safe.
        let scale = 2.0 / Float(fftSize)
        magnitudes = vDSP.multiply(scale, magnitudes)
        return magnitudes
    }
}
