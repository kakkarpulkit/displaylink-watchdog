import SwiftUI
import AppKit
import ServiceManagement

/// Content of the menu bar dropdown. Uses `.menu` style so it behaves like a
/// native macOS status-item menu (keyboard navigation, auto-dismiss, etc.).
struct MenuBarStatusView: View {

    @EnvironmentObject var engine: WatchdogEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status (non-interactive label)
        Text(engine.statusDescription)
            .font(.headline)

        if let lastFix = engine.lastFixDate {
            Text("Last fix: \(lastFix, style: .relative) ago")
                .foregroundStyle(.secondary)
        } else {
            Text(engine.lastFixResult)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("View Log") {
            openWindow(id: "log")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Toggle("Launch at Login", isOn: launchAtLoginBinding)

        Divider()

        Button("Quit DisplayLink Watchdog") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Helpers

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { engine.config.launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    engine.config.launchAtLogin = enabled
                } catch {
                    engine.logStore.log("Launch at Login error: \(error.localizedDescription)")
                }
            }
        )
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
