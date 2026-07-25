import SwiftUI
import BandwatchCore

@main
struct BandwatchApp: App {
    // Owned by the app delegate, not a fresh `@State` here, specifically so
    // `applicationShouldTerminate` (below) can reach the SAME session
    // instance the UI is bound to -- see AppDelegate's doc comment (C1).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(session: appDelegate.session)
        } label: {
            Image(systemName: appDelegate.session.isRunning ? "waveform.circle.fill" : "waveform.circle")
        }

        // Present the window at launch. Without this an app whose first scene
        // is a MenuBarExtra starts with NO window on screen — verified: zero
        // windows 12s after launch with no saved state — so launching it looks
        // like nothing happened. Requires macOS 15, which is why the package
        // floor is .v15.
        Window("Bandwatch", id: Self.monitorWindowID) {
            MonitorView(session: appDelegate.session, scheduler: appDelegate.scheduler)
        }
        .defaultLaunchBehavior(.presented)
        // Always present the main window at launch. Without disabling
        // restoration, a session that quit with the window closed would restore
        // that "no window" state and launch with nothing on screen.
        .restorationBehavior(.disabled)

        Window("Bandwatch Review", id: Self.reviewWindowID) {
            ReviewView(model: ReviewModel(databaseURL:
                RecordingPaths.defaultRoot().appendingPathComponent("bandwatch.sqlite")))
        }
        .defaultLaunchBehavior(.suppressed)   // do NOT open at launch; opened on demand

        Window("About Bandwatch", id: Self.aboutWindowID) {
            AboutView()
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            CommandMenu("Monitoring") {
                MonitoringActions(session: appDelegate.session)
            }
        }
    }

    static let monitorWindowID = "monitor"
    static let reviewWindowID = "review"
    static let aboutWindowID = "about"
    static let repoURL = "https://github.com/Dilcue/Bandwatch"
}

/// Owns the one `MonitoringSession` and makes sure quitting — through ANY
/// route (this menu's Quit item, Cmd-Q, the Dock's Quit, or logout, all of
/// which end up calling `NSApplication.terminate(_:)`) — cannot leave the
/// in-progress archive segment corrupted on disk (C1).
///
/// The bug this fixes: process termination does not run `deinit`, and a
/// FLAC file is unreadable until its writer is explicitly closed (verified
/// empirically — see the M3 review). With no delegate, nothing ever called
/// `session.stop()`/the coordinator's `shutdown()` on the quit path, so
/// EVERY quit corrupted whatever archive segment was currently open — up to
/// 60 minutes of audio, unopenable, with no gap row explaining the missing
/// coverage either.
///
/// `applicationWillTerminate` is NOT the right hook for this, even though
/// it is the first one that comes to mind: it runs synchronously on the
/// main thread as termination is already underway, and — being a `Void`-
/// returning callback with no way to signal "wait" — cannot delay
/// termination for the async coordinator work (closing the FLAC writer,
/// writing the final event clip, closing the database) to actually finish.
/// A fire-and-forget `Task` started from it would race process exit and
/// solve nothing.
///
/// `applicationShouldTerminate(_:)` returning `.terminateLater` is the
/// mechanism AppKit actually provides for this: it tells AppKit to hold
/// termination open, and the app is responsible for eventually calling
/// `NSApplication.reply(toApplicationShouldTerminate:)` once it is safe to
/// proceed. This is what actually blocks the process from exiting until
/// `session.shutdown()` — which awaits the coordinator all the way through
/// closing the segment's writer and the database (see its doc comment) —
/// has genuinely finished.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = MonitoringSession()

    // Owned alongside `session`, for the same reason: it must live for the
    // app's full lifetime so its 30s evaluation timer and keep-awake
    // assertion keep running whether or not the monitor window is open.
    // Depends on `session` directly above, so property initialization order
    // (top to bottom) already guarantees `session` exists first.
    lazy var scheduler = MonitoringScheduler(session: session)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bandwatch has no text-editing or view/toolbar commands, so the
        // standard Edit and View menus are just empty noise next to the app's
        // own menus. Remove them from the menu bar.
        if let main = NSApp.mainMenu {
            for title in ["Edit", "View"] {
                if let item = main.items.first(where: { $0.title == title }) {
                    main.removeItem(item)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await session.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The three monitoring actions shared by the menu-bar-icon dropdown and the
/// window menu bar's "Monitoring" menu, so the two can never drift apart.
struct MonitoringActions: View {
    @Bindable var session: MonitoringSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(session.isRunning ? "Stop Monitoring" : "Start Monitoring") {
            if session.isRunning {
                session.stop()
            } else {
                Task { await session.start() }
            }
        }
        Button("Open Window…") {
            openWindow(id: BandwatchApp.monitorWindowID)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Open Review…") {
            openWindow(id: BandwatchApp.reviewWindowID)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

/// Opens the custom About window from the App menu's "About Bandwatch" item.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Bandwatch") { openWindow(id: BandwatchApp.aboutWindowID) }
    }
}

private struct MenuBarContent: View {
    @Bindable var session: MonitoringSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Just the run state, NOT a live level readout. Reading `latestFrame`
        // here rebuilt the entire menu ~12x/sec while it was open, which reset
        // the mouse-hover highlight every frame and made items nearly impossible
        // to click (the selection "jumped"). `isRunning` only changes on
        // Start/Stop, so the open menu stays still. The live level lives in the
        // main window.
        Text(session.isRunning ? "Monitoring" : "Stopped")

        // Recording state must be visible without opening the window. Not
        // merely "is a session active" -- if writes are failing, that must
        // read as a problem here too, not as if recording were fine. Mirrors
        // `RecordingRow`'s health-over-intent indicator in `MonitorView`.
        Text(recordingSummary)

        MonitoringActions(session: session)

        Divider()
        // Deliberately just `terminate(nil)`, not a bespoke stop()+quit
        // sequence: `terminate(_:)` is the SAME path Cmd-Q and the Dock's
        // Quit take, and AppDelegate.applicationShouldTerminate(_:) is what
        // actually performs the clean shutdown (C1) -- for every route,
        // not just this button.
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private var recordingSummary: String {
        guard let status = session.recordingStatus, status.isRecording else { return "Not Recording" }
        if status.consecutiveWriteFailures > 0 {
            return "Recording — Writes Failing (\(status.consecutiveWriteFailures) in a Row)"
        }
        return "Recording — \(status.eventsWritten) Clips"
    }
}
