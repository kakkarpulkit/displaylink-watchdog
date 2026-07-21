// DisplayLink Watchdog — menu bar front-end.
//
// This app contains NO watchdog logic. It is a viewer and a remote control for
// the CLI daemon: it shells out to `displaylink-watchdog --selftest` and
// `--restart`, and tails the daemon's file log. That keeps one implementation
// of the decision logic, one durable log, and one thing to test.
//
// The problem it solves: a watchdog's failure mode is silence. `make status`
// answers "is it working" only if you remember to ask. An icon in the menu bar
// answers it without being asked.

import SwiftUI
import ServiceManagement

// MARK: - Configuration

enum Paths {
    static var installDir: String {
        ProcessInfo.processInfo.environment["DLW_INSTALL_DIR"]
            ?? NSHomeDirectory() + "/scripts"
    }
    static var binary: String { installDir + "/displaylink-watchdog" }
    static var log: String {
        ProcessInfo.processInfo.environment["DLW_LOG_PATH"]
            ?? NSHomeDirectory() + "/scripts/logs/displaylink-watchdog.log"
    }
    static let agentLabel = "com.displaylink-watchdog"
}

// MARK: - Bounded subprocess

/// Run a command with a hard time bound and capture its output.
///
/// Every subprocess here is bounded. A binary older than 1.1.0 ignores unknown
/// flags and daemonizes instead of exiting, which would hang the menu bar
/// permanently — never trust the child to terminate.
func runBounded(_ path: String, _ args: [String], timeout: TimeInterval = 15)
    -> (output: String, exitCode: Int32, timedOut: Bool)
{
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return ("not executable: \(path)", -1, false)
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    do { try proc.run() } catch {
        return ("failed to launch: \(error.localizedDescription)", -1, false)
    }

    // Read concurrently so a chatty child cannot deadlock on a full pipe buffer.
    var data = Data()
    let readQueue = DispatchQueue(label: "dlw.menubar.read")
    let done = DispatchSemaphore(value: 0)
    readQueue.async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        usleep(100_000)
    }

    if proc.isRunning {
        proc.terminate()
        usleep(200_000)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        _ = done.wait(timeout: .now() + 2)
        return (String(data: data, encoding: .utf8) ?? "", -1, true)
    }

    proc.waitUntilExit()
    _ = done.wait(timeout: .now() + 2)
    return (String(data: data, encoding: .utf8) ?? "", proc.terminationStatus, false)
}

// MARK: - Status model

@MainActor
final class WatchdogStatus: ObservableObject {

    enum Health {
        case healthy, problem, unknown

        var symbol: String {
            switch self {
            case .healthy: return "display"
            case .problem: return "exclamationmark.triangle.fill"
            case .unknown: return "display.trianglebadge.exclamationmark"
            }
        }
        var label: String {
            switch self {
            case .healthy: return "DisplayLink Watchdog — healthy"
            case .problem: return "DisplayLink Watchdog — needs attention"
            case .unknown: return "DisplayLink Watchdog — checking"
            }
        }
    }

    @Published private(set) var health: Health = .unknown
    @Published private(set) var summary: String = "Checking…"
    @Published private(set) var detail: [String] = []
    @Published private(set) var daemonRunning = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isBusy = false
    @Published var launchAtLogin = false

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 30

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        refresh()
        // Bind self strongly before the Task: capturing the optional `self`
        // directly inside concurrently-executing code is rejected by stricter
        // Swift concurrency checking (fine locally, fails on CI toolchains).
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.refresh()
            }
        }
    }

    deinit { timer?.invalidate() }

    /// Ask the daemon binary whether it would actually act, and ask launchd
    /// whether it is loaded. Both are needed: a running daemon with the wrong
    /// USB IDs is just as useless as one that is not running at all.
    func refresh() {
        guard !isBusy else { return }
        isBusy = true

        Task.detached(priority: .utility) {
            let selftest = runBounded(Paths.binary, ["--selftest"], timeout: 15)
            let running = Self.agentIsRunning()

            var lines = selftest.output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0.contains("ok ") || $0.contains("FAIL") }

            if selftest.timedOut {
                lines = ["Self-test timed out — binary may predate 1.1.0"]
            }

            let health: Health
            let summary: String
            if selftest.timedOut || selftest.exitCode < 0 {
                health = .unknown
                summary = "Cannot reach \(Paths.binary)"
            } else if !running {
                health = .problem
                summary = "Daemon not running"
            } else if selftest.exitCode != 0 {
                health = .problem
                summary = "Running, but would never act"
            } else {
                health = .healthy
                summary = "Healthy — loaded, running, matched to hardware"
            }

            await MainActor.run { [lines] in
                self.health = health
                self.summary = summary
                self.detail = lines
                self.daemonRunning = running
                self.lastChecked = Date()
                self.isBusy = false
            }
        }
    }

    func restartDisplayLink() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            _ = runBounded(Paths.binary, ["--restart"], timeout: 30)
            await MainActor.run { self.isBusy = false }
            await MainActor.run { self.refresh() }
        }
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            // Registration fails for unsigned builds; reflect reality rather
            // than showing a toggle that lies about its own state.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // nonisolated: called from a detached task, and it only touches the
    // filesystem and a subprocess — no actor state.
    nonisolated private static func agentIsRunning() -> Bool {
        let uid = getuid()
        let r = runBounded("/bin/launchctl",
                           ["print", "gui/\(uid)/\(Paths.agentLabel)"],
                           timeout: 10)
        guard r.exitCode == 0 else { return false }
        return r.output.contains("state = running")
    }
}

// MARK: - Menu

struct MenuContent: View {
    @EnvironmentObject var status: WatchdogStatus

    var body: some View {
        Text(status.summary)

        if !status.detail.isEmpty {
            Divider()
            ForEach(Array(status.detail.enumerated()), id: \.offset) { _, line in
                Text(line.trimmingCharacters(in: .whitespaces))
            }
        }

        Divider()

        Button(status.isBusy ? "Working…" : "Restart DisplayLink Now") {
            status.restartDisplayLink()
        }
        .disabled(status.isBusy)

        Button("Re-check Now") { status.refresh() }
            .disabled(status.isBusy)

        Button("Open Log") { status.openLog() }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { status.launchAtLogin },
            set: { status.setLaunchAtLogin($0) }
        ))

        if let checked = status.lastChecked {
            Text("Last checked \(checked.formatted(date: .omitted, time: .standard))")
        }

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - App

@main
struct DisplayLinkWatchdogMenuBarApp: App {
    @StateObject private var status = WatchdogStatus()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(status)
        } label: {
            Image(systemName: status.health.symbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(status.health.label)
        }
        .menuBarExtraStyle(.menu)
    }
}
