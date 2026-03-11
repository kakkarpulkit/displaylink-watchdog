import Foundation
import IOKit
import IOKit.usb
import CoreGraphics

// MARK: - WatchdogEngine

/// The central component of the app. Owns all watching/fixing logic and
/// publishes observable state for the SwiftUI layer.
///
/// Threading model:
/// - `workQueue` is a serial background queue for all fix logic.
/// - Published properties are always mutated on the main thread.
/// - IOKit/CG callbacks arrive on the main thread (both watchers ensure this).
final class WatchdogEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var displayCount: Int = 0
    @Published private(set) var isAdapterPresent: Bool = false
    @Published private(set) var isDisplayLinkInstalled: Bool = false
    @Published private(set) var lastFixDate: Date?
    @Published private(set) var lastFixResult: String = "No fix attempted"

    // MARK: - Sub-components (accessible to views)

    let config:   WatchdogConfig
    let logStore: LogStore

    // MARK: - Private

    private let restarter: DisplayLinkRestarter
    private let workQueue = DispatchQueue(
        label: "com.kakkarpulkit.displaylink-watchdog.work",
        qos: .utility
    )
    private var usbWatcher:     USBWatcher?
    private var displayWatcher: DisplayWatcher?
    private var pollTimer:      Timer?
    private var lastFixTime:    Date = .distantPast

    // How long to wait after USB attach before attempting fix (adapter needs a moment to initialise)
    private let postAttachDelay: TimeInterval = 2.0
    // Polling interval and max iterations to check whether a fix succeeded
    private let postRestartPollDelay: TimeInterval = 0.5
    private let postRestartPollMax = 16

    // MARK: - Init / teardown

    init(
        config:    WatchdogConfig        = WatchdogConfig(),
        logStore:  LogStore              = LogStore(),
        restarter: DisplayLinkRestarter  = LiveDisplayLinkRestarter()
    ) {
        self.config    = config
        self.logStore  = logStore
        self.restarter = restarter
        start()
    }

    deinit {
        stop()
    }

    func start() {
        logStore.log("=== DisplayLink Watchdog started (PID \(ProcessInfo.processInfo.processIdentifier)) ===")
        logStore.log("Config: VID=\(config.vendorIDHex) PID=\(config.productIDHex) expected=\(config.expectedDisplays) base=\(config.baseDisplays)")

        refreshState()
        checkDisplayLinkInstalled()
        startUSBWatcher()
        startDisplayWatcher()
        startPollTimer()

        // Attempt a fix on launch in case the app is started after a display problem
        workQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.attemptFix(trigger: "startup")
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        usbWatcher?.stop()
        usbWatcher = nil
        displayWatcher = nil
    }

    // MARK: - Public helpers

    /// Force a manual fix attempt and refresh the display/adapter state.
    func triggerManualFix() {
        workQueue.async { [weak self] in
            self?.attemptFix(trigger: "manual")
        }
    }

    func refreshState() {
        let count   = externalDisplayCount()
        let adapter = adapterIsPresent()
        DispatchQueue.main.async { [weak self] in
            self?.displayCount   = count
            self?.isAdapterPresent = adapter
        }
    }

    // MARK: - Watcher setup

    private func startUSBWatcher() {
        usbWatcher = USBWatcher(
            vendorID:  config.vendorID,
            productID: config.productID,
            onAdded: { [weak self] in
                guard let self else { return }
                // CG can take a moment to enumerate displays after the adapter appears on USB
                workQueue.asyncAfter(deadline: .now() + postAttachDelay) { [weak self] in
                    self?.logStore.log("DisplayLink adapter appeared on USB bus.")
                    self?.attemptFix(trigger: "usb-attach")
                }
            }
        )
    }

    private func startDisplayWatcher() {
        displayWatcher = DisplayWatcher(onDisplayAdded: { [weak self] in
            self?.workQueue.async { [weak self] in
                self?.attemptFix(trigger: "display-added")
            }
        })
    }

    private func startPollTimer() {
        // Timer must be added to the main run loop since it's created on the main thread
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: config.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.workQueue.async { [weak self] in
                self?.attemptFix(trigger: "poll")
            }
        }
    }

    // MARK: - Fix logic (runs on workQueue)

    /// Mirrors the decision logic from the original CLI daemon.
    /// Must be called on `workQueue`.
    private func attemptFix(trigger: String) {
        // --- Guard: cooldown ---
        let now = Date()
        guard now.timeIntervalSince(lastFixTime) >= config.cooldown else { return }

        // --- Guard: adapter present ---
        let adapter = adapterIsPresent()
        let displays = externalDisplayCount()

        // Update UI state on every event so the menu bar stays accurate
        DispatchQueue.main.async { [weak self] in
            self?.displayCount     = displays
            self?.isAdapterPresent = adapter
        }

        guard adapter else { return }
        // --- Guard: all displays already up ---
        guard displays < config.expectedDisplays else { return }
        // --- Guard: base (non-DisplayLink) displays must be up first ---
        guard displays >= config.baseDisplays else { return }

        // Decision: restart
        lastFixTime = now
        logStore.log("\(displays)/\(config.expectedDisplays) displays (\(trigger)). Restarting DisplayLink…")

        restarter.restart(log: { [weak self] m in self?.logStore.log(m) })

        // Poll briefly to see whether the fix succeeded
        var fixed = false
        for i in 1 ... postRestartPollMax {
            Thread.sleep(forTimeInterval: postRestartPollDelay)
            let current = externalDisplayCount()
            if current >= config.expectedDisplays {
                let elapsed = String(format: "%.1f", Double(i) * postRestartPollDelay)
                logStore.log("Fixed: \(current) displays up (\(elapsed)s).")
                fixed = true
                DispatchQueue.main.async { [weak self] in
                    self?.displayCount = current
                }
                break
            }
        }

        if !fixed {
            logStore.log("Restart did not recover all displays. Will retry on next event.")
        }

        let result = fixed
            ? "Fixed at \(Self.shortTime(now))"
            : "Attempted fix at \(Self.shortTime(now)) — displays not recovered"

        DispatchQueue.main.async { [weak self] in
            self?.lastFixDate   = now
            self?.lastFixResult = result
        }
    }

    // MARK: - Low-level queries (safe to call from any thread)

    private func adapterIsPresent() -> Bool {
        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID]  = config.vendorID
        matching[kUSBProductID] = config.productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    private func externalDisplayCount() -> Int {
        var ids   = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return 0 }
        return (0 ..< Int(count)).filter { CGDisplayIsBuiltin(ids[$0]) == 0 }.count
    }

    private func checkDisplayLinkInstalled() {
        let paths = [
            "/Applications/DisplayLink Manager.app",
            "/Applications/Utilities/DisplayLink Manager.app",
        ]
        let installed = paths.contains { FileManager.default.fileExists(atPath: $0) }
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayLinkInstalled = installed
        }
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Derived display state (for views)

    var statusDescription: String {
        guard isAdapterPresent else {
            return isDisplayLinkInstalled
                ? "No DisplayLink adapter detected"
                : "DisplayLink Manager not installed"
        }
        if displayCount >= config.expectedDisplays {
            return "\(displayCount)/\(config.expectedDisplays) displays connected"
        }
        return "\(displayCount)/\(config.expectedDisplays) — watching…"
    }

    /// SF Symbol name reflecting current health status.
    var menuBarSymbol: String {
        guard isAdapterPresent else { return "display.trianglebadge.exclamationmark" }
        return displayCount >= config.expectedDisplays ? "display.2" : "display.trianglebadge.exclamationmark"
    }
}
