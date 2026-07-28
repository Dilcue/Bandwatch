import Foundation

/// Directory and filename layout for recorded audio.
///
/// Pure logic, no I/O — creating directories is the coordinator's job.
public struct RecordingPaths: Sendable {
    public let root: URL
    public let timeZone: TimeZone

    public init(root: URL, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    public var eventsDirectory: URL { root.appendingPathComponent("events") }
    public var databaseURL: URL { root.appendingPathComponent("bandwatch.sqlite") }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Bandwatch")
    }

    /// `yyyy-MM-dd`. Fixed locale and calendar: a user's regional settings must
    /// never change how evidence files are named. Timezone is pinned to
    /// `self.timeZone` (default: the host's current zone) so the intent —
    /// group by local calendar day — is explicit rather than implied by
    /// `DateFormatter`'s ambient default.
    public func dayDirectoryName(for date: Date) -> String {
        Self.makeDayFormatter(timeZone: timeZone).string(from: date)
    }

    /// `yyyy-MM-dd'T'HH-mm-ss-SSSZZZ`. Colons are illegal in file names, so the
    /// time separator is `-`.
    ///
    /// Includes milliseconds and a UTC offset for two reasons:
    ///
    /// 1. One-second resolution let two events within the same second produce
    ///    byte-identical filenames, silently overwriting recorded evidence.
    ///    The detector's `minimumDuration` is 1.5s, so millisecond resolution
    ///    cannot plausibly collide.
    /// 2. Without a pinned/visible offset, local wall-clock time is ambiguous
    ///    across a DST "fall back": two instants an hour apart both read
    ///    "1:30am" and would format identically. The offset disambiguates
    ///    them (e.g. `-0400` vs `-0500`) while keeping the stamp in local time
    ///    — which is what a human reviewing evidence expects — and matches
    ///    the offset-qualified ISO8601 timestamps `EventStore` persists, so a
    ///    filename can always be mapped back to its database row.
    ///
    /// Do not simplify this back to `HH-mm-ss`: that reintroduces both a data
    /// loss bug (same-second overwrite) and a DST ambiguity bug.
    public func timestampName(for date: Date) -> String {
        Self.makeStampFormatter(timeZone: timeZone).string(from: date)
    }

    public func eventClipURL(startingAt date: Date) -> URL {
        eventsDirectory
            .appendingPathComponent(dayDirectoryName(for: date))
            .appendingPathComponent(timestampName(for: date) + ".flac")
    }

    private static func makeDayFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func makeStampFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSSZZZ"
        return f
    }
}
