import Foundation
import IOKit
import IOKit.usb
import CoreGraphics

let buildVersion = "1.1.0"

// -- Config (from environment or defaults) --------------------------------
// Override via environment variables in the LaunchAgent plist:
//   DLW_VENDOR_ID       USB Vendor ID of DisplayLink adapter (hex, e.g. 0x17e9)
//   DLW_PRODUCT_ID      USB Product ID of DisplayLink adapter (hex, e.g. 0x6000)
//   DLW_EXPECTED         Total external displays expected
//   DLW_BASE             Minimum non-DisplayLink displays before attempting fix
//   DLW_COOLDOWN         Seconds between fix attempts
//   DLW_LOG_PATH         Log file path
//   DLW_POLL_INTERVAL    Fallback poll interval in seconds

func envInt(_ key: String, default d: Int) -> Int {
    guard let v = ProcessInfo.processInfo.environment[key] else { return d }
    if v.hasPrefix("0x") || v.hasPrefix("0X") {
        return Int(v.dropFirst(2), radix: 16) ?? d
    }
    return Int(v) ?? d
}
func envDouble(_ key: String, default d: Double) -> Double {
    guard let v = ProcessInfo.processInfo.environment[key] else { return d }
    return Double(v) ?? d
}
func envString(_ key: String, default d: String) -> String {
    return ProcessInfo.processInfo.environment[key] ?? d
}

let vendorID        = envInt("DLW_VENDOR_ID", default: 0x17e9)
let productID       = envInt("DLW_PRODUCT_ID", default: 0x6000)
let expectedDisplays = UInt32(envInt("DLW_EXPECTED", default: 3))
let baseDisplays     = UInt32(envInt("DLW_BASE", default: 2))
let cooldownSeconds  = envDouble("DLW_COOLDOWN", default: 30)
let pollInterval     = envDouble("DLW_POLL_INTERVAL", default: 300)
// Heartbeat exists so an idle daemon is distinguishable from a dead one. Without
// it the log is silent until a fix fires, and "working, nothing to do" looks
// exactly like "died months ago".
let heartbeatHours   = envDouble("DLW_HEARTBEAT_HOURS", default: 6)
let postAttachDelay: TimeInterval = 2
let postRestartPoll  = (delay: 0.5, max: 16)
let logPath = envString("DLW_LOG_PATH", default: {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/scripts/logs/displaylink-watchdog.log"
}())
let maxLogBytes = 524_288

// -- Serial queue for all state and work ----------------------------------
let workQueue = DispatchQueue(label: "displaylink-watchdog")

// -- State (only accessed on workQueue) -----------------------------------
var lastFixTime: Date = .distantPast
var notifyPort: IONotificationPortRef?
var addedIterator: io_iterator_t = 0

// -- Logging (only called on workQueue) -----------------------------------
let logFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()
var logBytesWritten = 0

func log(_ msg: String) {
    let line = "\(logFormatter.string(from: Date())): \(msg)\n"
    let url = URL(fileURLWithPath: logPath)

    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    if logBytesWritten > maxLogBytes {
        let old = logPath + ".old"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: logPath, toPath: old)
        logBytesWritten = 0
    }

    let data = line.data(using: .utf8)!
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
    logBytesWritten += data.count
}

// -- USB Presence Check ---------------------------------------------------
func isAdapterPresent() -> Bool {
    let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matching[kUSBVendorID] = vendorID
    matching[kUSBProductID] = productID
    let existing = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
    guard existing != IO_OBJECT_NULL else { return false }
    IOObjectRelease(existing)
    return true
}

// -- Display Counting (CoreGraphics — microseconds, no process spawn) -----
func getExternalDisplayCount() -> UInt32 {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return 0 }
    var external: UInt32 = 0
    for i in 0..<Int(count) {
        if CGDisplayIsBuiltin(ids[i]) == 0 { external += 1 }
    }
    return external
}

// -- Process Helper -------------------------------------------------------
@discardableResult
func run(_ path: String, _ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// -- DisplayLink Restart --------------------------------------------------
func restartDisplayLink() {
    run("/usr/bin/killall", "DisplayLinkUserAgent")
    run("/usr/bin/killall", "DisplayLinkXpcService")

    for _ in 0..<5 {
        if run("/usr/bin/pgrep", "-q", "DisplayLink") != 0 { break }
        Thread.sleep(forTimeInterval: 0.5)
    }

    run("/usr/bin/open", "-a", "DisplayLink Manager")
}

// -- Core Fix Logic -------------------------------------------------------
func attemptFix(trigger: String) {
    if Date().timeIntervalSince(lastFixTime) < cooldownSeconds { return }
    guard isAdapterPresent() else { return }

    let count = getExternalDisplayCount()
    if count >= expectedDisplays { return }
    if count < baseDisplays { return }

    lastFixTime = Date()
    log("\(count)/\(expectedDisplays) displays (\(trigger)). Restarting DisplayLink...")
    restartDisplayLink()

    for i in 1...postRestartPoll.max {
        Thread.sleep(forTimeInterval: postRestartPoll.delay)
        let c = getExternalDisplayCount()
        if c >= expectedDisplays {
            log("Fixed: \(c) displays up (\(Double(i) * postRestartPoll.delay)s).")
            return
        }
    }

    log("Restart failed. Waiting for next event.")
}

// -- IOKit USB Matching ---------------------------------------------------
func deviceAdded(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
        IOObjectRelease(device)
    }
    workQueue.asyncAfter(deadline: .now() + postAttachDelay) {
        log("DisplayLink adapter appeared on USB bus.")
        attemptFix(trigger: "usb-attach")
    }
}

func startUSBWatcher() {
    notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard let np = notifyPort else {
        workQueue.sync { log("FATAL: IONotificationPortCreate failed.") }
        exit(1)
    }

    let src = IONotificationPortGetRunLoopSource(np).takeUnretainedValue()
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)

    let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matching[kUSBVendorID] = vendorID
    matching[kUSBProductID] = productID

    let kr = IOServiceAddMatchingNotification(
        np, kIOFirstMatchNotification, matching as CFDictionary,
        deviceAdded, nil, &addedIterator)
    guard kr == KERN_SUCCESS else {
        workQueue.sync { log("FATAL: IOServiceAddMatchingNotification: \(kr)") }
        exit(1)
    }

    while case let device = IOIteratorNext(addedIterator), device != IO_OBJECT_NULL {
        IOObjectRelease(device)
    }
}

// -- CoreGraphics Display Reconfiguration Callback ------------------------
func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.contains(.addFlag) else { return }
    workQueue.async { attemptFix(trigger: "display-added") }
}

func startDisplayWatcher() {
    CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
}

// -- Fallback Poll --------------------------------------------------------
func startFallbackPoll() {
    let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
        workQueue.async { attemptFix(trigger: "poll") }
    }
    RunLoop.current.add(timer, forMode: .default)
}

// -- Signal Handling ------------------------------------------------------
var _signalSources: [DispatchSourceSignal] = []

func setupSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: workQueue)
        src.setEventHandler {
            log("Received signal \(sig). Exiting.")
            exit(0)
        }
        src.resume()
        signal(sig, SIG_IGN)
        _signalSources.append(src)
    }
}

// -- Heartbeat ------------------------------------------------------------
func startHeartbeat() {
    guard heartbeatHours > 0 else { return }
    let timer = Timer(timeInterval: heartbeatHours * 3600, repeats: true) { _ in
        workQueue.async {
            let count = getExternalDisplayCount()
            let usb = isAdapterPresent() ? "present" : "ABSENT"
            log("Heartbeat: \(count)/\(expectedDisplays) displays, adapter \(usb).")
        }
    }
    RunLoop.current.add(timer, forMode: .default)
}

// -- Self Test ------------------------------------------------------------
// Verifies every precondition the daemon depends on. The failure mode this
// guards against is silence: wrong USB IDs, an unwritable log, or a mismatched
// display count all cause the daemon to run forever and never act.
func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "  ok  " : " FAIL ") \(name): \(detail)")
        if !ok { failures += 1 }
    }

    print("displaylink-watchdog self-test")
    print("Config: VID=0x\(String(vendorID, radix: 16)) PID=0x\(String(productID, radix: 16)) "
        + "expected=\(expectedDisplays) base=\(baseDisplays)")
    print("")

    let adapter = isAdapterPresent()
    check("usb adapter", adapter,
          adapter ? "found at VID 0x\(String(vendorID, radix: 16))/PID 0x\(String(productID, radix: 16))"
                  : "NOT found — check DLW_VENDOR_ID/DLW_PRODUCT_ID against `system_profiler SPUSBDataType`")

    let count = getExternalDisplayCount()
    check("display count", count >= baseDisplays,
          "\(count) external display(s) online, base=\(baseDisplays), expected=\(expectedDisplays)")

    check("config sanity", expectedDisplays > baseDisplays,
          expectedDisplays > baseDisplays
              ? "expected(\(expectedDisplays)) > base(\(baseDisplays))"
              : "expected(\(expectedDisplays)) must exceed base(\(baseDisplays)) or a fix can never trigger")

    let logDir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let writable = FileManager.default.isWritableFile(atPath: logDir)
    check("log writable", writable, writable ? logPath : "cannot write to \(logDir)")

    let dlManager = FileManager.default.fileExists(atPath: "/Applications/DisplayLink Manager.app")
    check("DisplayLink Manager", dlManager,
          dlManager ? "installed" : "not found at /Applications/DisplayLink Manager.app")

    print("")
    if failures == 0 {
        print("All checks passed. A fix would trigger if displays dropped to "
            + "\(baseDisplays)..\(expectedDisplays - 1) with the adapter present.")
    } else {
        print("\(failures) check(s) failed — the daemon would run but never act.")
    }
    return failures == 0 ? 0 : 1
}

// -- Main -----------------------------------------------------------------
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains("--selftest") {
    exit(runSelfTest())
}
if cliArgs.contains("--version") {
    print("displaylink-watchdog \(buildVersion)")
    exit(0)
}
if cliArgs.contains("--help") || cliArgs.contains("-h") {
    print("""
    displaylink-watchdog \(buildVersion)

    Usage:
      displaylink-watchdog              run as a daemon (normally via LaunchAgent)
      displaylink-watchdog --selftest   verify config against live hardware
      displaylink-watchdog --version    print version
      displaylink-watchdog --help       this message

    Configuration is via environment variables — see README.
    """)
    exit(0)
}
if let unknown = cliArgs.first(where: { $0.hasPrefix("-") }) {
    FileHandle.standardError.write("unknown option: \(unknown)\nTry --help\n".data(using: .utf8)!)
    exit(2)
}

workQueue.sync {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? Int {
        logBytesWritten = size
    }
    log("=== Started (PID \(ProcessInfo.processInfo.processIdentifier)) ===")
    log("Config: VID=0x\(String(vendorID, radix: 16)) PID=0x\(String(productID, radix: 16)) expected=\(expectedDisplays) base=\(baseDisplays)")
}
setupSignalHandlers()
startUSBWatcher()
startDisplayWatcher()
startFallbackPoll()
startHeartbeat()
workQueue.async { attemptFix(trigger: "startup") }
CFRunLoopRun()
