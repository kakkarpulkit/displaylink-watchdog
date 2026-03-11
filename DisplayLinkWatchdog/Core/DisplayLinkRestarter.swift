import Foundation
import AppKit

// MARK: - Protocol

/// Encapsulates the logic for restarting the DisplayLink driver.
/// Isolated behind a protocol so tests can inject a mock and so the
/// implementation can be swapped for a sandboxed XPC approach later.
protocol DisplayLinkRestarter {
    /// Synchronously kills and relaunches the DisplayLink driver.
    /// This is called from a background queue, so blocking is acceptable.
    /// Use `log` to emit status messages during the operation.
    func restart(log: (String) -> Void)
}

// MARK: - Live implementation

/// Kills DisplayLink processes with `/usr/bin/killall` (requires non-sandboxed app),
/// then relaunches via `NSWorkspace.shared.openApplication`.
final class LiveDisplayLinkRestarter: DisplayLinkRestarter {

    private static let displayLinkManagerPaths = [
        "/Applications/DisplayLink Manager.app",
        "/Applications/Utilities/DisplayLink Manager.app",
    ]

    func restart(log: (String) -> Void) {
        log("Killing DisplayLink processes…")
        run("/usr/bin/killall", "DisplayLinkUserAgent")
        run("/usr/bin/killall", "DisplayLinkXpcService")

        // Give processes a moment to exit before relaunching
        waitForProcessesToExit(name: "DisplayLink", attempts: 10, interval: 0.5)

        log("Relaunching DisplayLink Manager…")
        relaunch(log: log)
    }

    // MARK: - Private

    private func relaunch(log: (String) -> Void) {
        guard let appURL = Self.displayLinkManagerPaths
            .map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            log("DisplayLink Manager not found. Install it from displaylink.com")
            return
        }

        // NSWorkspace.openApplication must be called on the main thread.
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    log("Could not open DisplayLink Manager: \(error.localizedDescription)")
                }
            }
        }
    }

    private func waitForProcessesToExit(name: String, attempts: Int, interval: TimeInterval) {
        for _ in 0 ..< attempts {
            guard isProcessRunning(name) else { break }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func isProcessRunning(_ name: String) -> Bool {
        run("/usr/bin/pgrep", "-q", name) == 0
    }

    @discardableResult
    private func run(_ path: String, _ args: String...) -> Int32 {
        let p = Process()
        p.executableURL    = URL(fileURLWithPath: path)
        p.arguments        = args
        p.standardOutput   = FileHandle.nullDevice
        p.standardError    = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
