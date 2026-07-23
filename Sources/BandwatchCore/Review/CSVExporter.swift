import Foundation

/// Renders review data as RFC-4180-style CSV for the evidence bundle.
public enum CSVExporter {
    private static func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func num(_ d: Double) -> String { String(format: "%g", d) }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        f.timeZone = TimeZone.current
        return f
    }

    public static func eventsCSV(_ rows: [EventRecord]) -> String {
        let iso = isoFormatter()
        var out = "id,started_at,duration_sec,peak_dbfs,mean_dbfs,band_low_hz,band_high_hz,threshold_dbfs,device_uid,clip_path"
        for r in rows {
            out += "\n" + [
                String(r.id), iso.string(from: r.startedAt), num(r.durationSec),
                num(r.peakDBFS), num(r.meanDBFS), num(r.bandLowHz), num(r.bandHighHz),
                num(r.thresholdDBFS), field(r.deviceUID),
                "\"" + r.clipPath.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            ].joined(separator: ",")
        }
        return out
    }

    public static func gapsCSV(_ rows: [GapRecord]) -> String {
        let iso = isoFormatter()
        var out = "id,started_at,ended_at,reason"
        for r in rows {
            let fields = [
                String(r.id),
                iso.string(from: r.startedAt),
                r.endedAt.map { iso.string(from: $0) } ?? "",
                r.reason.rawValue
            ]
            out += "\n" + fields.joined(separator: ",")
        }
        return out
    }
}
