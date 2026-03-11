import SwiftUI

@main
struct DisplayLinkWatchdogApp: App {

    @StateObject private var engine = WatchdogEngine()

    var body: some Scene {
        // ── Menu bar extra ──────────────────────────────────────────────────
        // .menu style renders as a native NSMenu — proper keyboard navigation,
        // auto-dismiss, and the standard macOS menu-item appearance.
        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(engine.statusDescription)
        }
        .menuBarExtraStyle(.menu)

        // ── Settings window (Cmd+, / from menu) ────────────────────────────
        Settings {
            SettingsView()
                .environmentObject(engine)
        }

        // ── Log window ──────────────────────────────────────────────────────
        Window("Watchdog Log", id: "log") {
            LogView()
                .environmentObject(engine.logStore)
        }
        .windowResizability(.contentSize)
    }
}
