import SwiftUI

/// Explicit light and dark chart palettes.
///
/// Dark mode is designed, not derived: the app runs overnight in a dark room and
/// is checked at 2am. Each mode gets its own steps against its own surface.
enum Palette {
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.11)
            : Color(red: 0.99, green: 0.99, blue: 1.00)
    }

    /// The single data series color.
    static func series(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.45, green: 0.72, blue: 1.00)
            : Color(red: 0.11, green: 0.39, blue: 0.75)
    }

    /// The selected-band shaded region.
    static func bandFill(_ scheme: ColorScheme) -> Color {
        series(scheme).opacity(scheme == .dark ? 0.22 : 0.14)
    }

    /// Threshold reference rule — deliberately distinct from the series color.
    static func threshold(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.62, blue: 0.35)
            : Color(red: 0.78, green: 0.35, blue: 0.06)
    }

    /// Active-event shading.
    static func eventFill(_ scheme: ColorScheme) -> Color {
        threshold(scheme).opacity(scheme == .dark ? 0.20 : 0.13)
    }

    /// Input-health warning (e.g. sustained near-silence suggesting a dead
    /// signal path). Deliberately a distinct hue from `threshold`'s orange
    /// (which marks the level-rule reference line) and from error red (which
    /// means capture has actually failed) -- a gold/amber, not orange or red --
    /// so the three states read as unmistakably different at a glance,
    /// including at 2am in a dark room.
    static func warning(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.00, green: 0.85, blue: 0.20)
            : Color(red: 0.62, green: 0.49, blue: 0.02)
    }

    static func grid(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88)
    }

    static func mutedInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.50)
    }
}
