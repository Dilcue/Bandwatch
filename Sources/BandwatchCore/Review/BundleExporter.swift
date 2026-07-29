import Foundation

@MainActor
public enum BundleExporter {
    public struct BundleSummary: Equatable, Sendable {
        public let clipsIncluded: Int
        public let clipsMissing: Int
    }

    public static func export(_ data: ReportData, to destinationZip: URL, workDir: URL) throws -> BundleSummary {
        let fm = FileManager.default
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.dateFormat = "yyyy-MM-dd"
        let name = "Bandwatch-Evidence-\(dayFmt.string(from: data.rangeStart))_to_\(dayFmt.string(from: data.rangeEnd))"
        let root = workDir.appendingPathComponent(name)
        let clipsDir = root.appendingPathComponent("clips")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: clipsDir, withIntermediateDirectories: true)

        try ReportRenderer.renderPDF(data, to: root.appendingPathComponent("report.pdf"))
        try CSVExporter.eventsCSV(data.events).write(to: root.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
        try CSVExporter.gapsCSV(data.gaps).write(to: root.appendingPathComponent("gaps.csv"), atomically: true, encoding: .utf8)

        var included = 0, missing = 0
        for e in data.events {
            let src = URL(fileURLWithPath: e.clipPath)
            guard fm.fileExists(atPath: src.path) else {
                missing += 1
                continue
            }
            let dest = clipsDir.appendingPathComponent("\(e.id)-\(src.lastPathComponent)")
            do {
                try fm.copyItem(at: src, to: dest)
                included += 1
            } catch {
                // Copy failed (permissions, disk full, TOCTOU deletion, collision, etc.) —
                // the clip is not actually in the bundle, so it must be counted honestly.
                missing += 1
            }
        }

        let readmeFmt = DateFormatter()
        readmeFmt.locale = Locale(identifier: "en_US_POSIX")
        readmeFmt.timeZone = .current
        readmeFmt.dateFormat = "MMM d, yyyy"
        let speechNote = data.mayContainSpeech ? "\n\n\(ReportData.speechWarning)" : ""
        // The missing count is 0 in normal use — Bandwatch never deletes or expires
        // clips — so the summary omits it entirely unless a clip is genuinely absent
        // (a write error during recording, a file removed outside the app, or a copy
        // failure here). When that happens the bundle discloses it plainly rather
        // than silently shipping fewer clips than events.
        let missingSummary = missing > 0 ? "   Clips missing: \(missing)" : ""
        let missingNote = missing > 0 ? """


        Note: \(missing) event\(missing == 1 ? "" : "s") in this range \
        \(missing == 1 ? "has" : "have") no clip in this bundle — the audio file was \
        not found on disk or could not be copied. Bandwatch never deletes or expires \
        clips; a missing file indicates a write error during recording or a file \
        removed outside the app.
        """ : ""
        let readme = """
        Bandwatch evidence bundle
        Range: \(readmeFmt.string(from: data.rangeStart)) to \(readmeFmt.string(from: data.rangeEnd))
        Events: \(data.events.count)   Clips included: \(included)\(missingSummary)

        report.pdf   — formatted summary, coverage, event table, methodology
        events.csv   — every event in range
        gaps.csv     — every coverage gap in range (intervals not monitored)
        clips/       — band-filtered audio for the recorded events

        Levels are dBFS, not calibrated SPL. Audio is band-filtered. See the
        methodology note in report.pdf.\(speechNote)\(missingNote)
        """
        try readme.write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: destinationZip)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", root.path, destinationZip.path]
        let stderrPipe = Pipe()
        p.standardError = stderrPipe
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = stderrText.isEmpty
                ? "ditto exited with status \(p.terminationStatus)"
                : "ditto exited with status \(p.terminationStatus): \(stderrText)"
            throw NSError(domain: "BundleExporter", code: Int(p.terminationStatus),
                           userInfo: [NSLocalizedDescriptionKey: message])
        }

        // Success: only the zip should remain — the assembled working folder
        // (including copied evidence audio) must not be left unmanaged on disk.
        try? fm.removeItem(at: root)

        return BundleSummary(clipsIncluded: included, clipsMissing: missing)
    }
}
