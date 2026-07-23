import Foundation

/// Reduces magnitude bins to at most one point per horizontal pixel, keeping the
/// MAXIMUM in each bucket so narrow peaks survive — they are the signal.
///
/// The spectrum's frequency axis is logarithmic, so bins are not evenly spread
/// across pixels: low-frequency bins spread over many pixels while
/// high-frequency bins crowd into a handful. Bucketing is therefore done by
/// each bin's pixel column (the same log-mapping the chart itself uses to
/// place `hz` on the x axis), not by a fixed bin stride or index range.
///
/// A mean- or stride-based reduction would smear or skip a narrow tone —
/// exactly the kind of signal this app exists to find — so each bucket keeps
/// whichever bin had the highest magnitude, discarding the rest.
public func decimateForDisplay(
    magnitudes: [Float],
    binWidthHz: Double,
    minHz: Double,
    maxHz: Double,
    pixelWidth: Int
) -> [(hz: Double, magnitude: Float)] {
    guard !magnitudes.isEmpty,
          pixelWidth > 0,
          minHz > 0,
          maxHz > minHz,
          binWidthHz > 0
    else { return [] }

    let logMin = log10(minHz)
    let logMax = log10(maxHz)
    guard logMax > logMin, logMax.isFinite, logMin.isFinite else { return [] }

    // Mirrors `SpectrumChart.xPosition(forHz:width:)`: the same log mapping
    // used to place a frequency on the chart's x axis is used here to decide
    // which pixel column a bin's magnitude contributes to.
    func pixelColumn(forHz hz: Double) -> Int {
        let clamped = min(max(hz, minHz), maxHz)
        let t = (log10(clamped) - logMin) / (logMax - logMin)
        let x = t * Double(pixelWidth)
        return min(max(Int(x), 0), pixelWidth - 1)
    }

    var buckets: [Int: (hz: Double, magnitude: Float)] = [:]
    buckets.reserveCapacity(min(magnitudes.count, pixelWidth))

    for (bin, magnitude) in magnitudes.enumerated() {
        let hz = Double(bin) * binWidthHz
        guard hz >= minHz, hz <= maxHz else { continue }

        let column = pixelColumn(forHz: hz)
        if let existing = buckets[column] {
            if magnitude > existing.magnitude {
                buckets[column] = (hz, magnitude)
            }
        } else {
            buckets[column] = (hz, magnitude)
        }
    }

    return buckets.values.sorted { $0.hz < $1.hz }
}
