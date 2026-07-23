import SwiftUI
import AppKit

/// About window: app identity, author, and links. Custom (not the stock
/// about panel) for clickable links and app-matched styling.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Bandwatch")
                .font(.title2.bold())
                .foregroundStyle(Palette.primaryInk(scheme))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(Palette.mutedInk(scheme))
            Text("Chris Connar")
                .font(.callout)
                .foregroundStyle(Palette.primaryInk(scheme))
            HStack(spacing: 16) {
                Link("chrisconnar.com", destination: URL(string: "https://chrisconnar.com")!)
                Link("GitHub", destination: URL(string: BandwatchApp.repoURL)!)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 320)
        .background(Palette.surface(scheme))
    }
}
