import Foundation

// Unit tests for displaylink-monitor decision logic.
//
// These test the behavioral contracts that matter for correctness:
// - When should a fix be attempted vs skipped?
// - What event sequences lead to action?
// - Does cooldown prevent hammering?
//
// The decision logic is extracted as a pure function so it can be tested
// without hardware. If the real attemptFix() changes its decision rules,
// this function must be updated to match — and the tests will catch
// if the new rules violate expected behavior.

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition { print("  PASS: \(msg)"); passed += 1 }
    else { print("  FAIL: \(msg) (\(file):\(line))"); failed += 1 }
}

// -- Decision function (mirrors attemptFix control flow) ------------------
enum FixAction: Equatable, CustomStringConvertible {
    case skip(String)
    case restart

    var description: String {
        switch self {
        case .skip(let r): return "skip(\(r))"
        case .restart: return "restart"
        }
    }
}

func decideFix(
    secsSinceLastFix: TimeInterval,
    cooldown: TimeInterval,
    adapterPresent: Bool,
    displays: UInt32,
    expected: UInt32,
    base: UInt32
) -> FixAction {
    if secsSinceLastFix < cooldown { return .skip("cooldown") }
    if !adapterPresent { return .skip("no-adapter") }
    if displays >= expected { return .skip("displays-ok") }
    if displays < base { return .skip("base-not-ready") }
    return .restart
}

// =========================================================================
print("=== Core decision: when to restart ===")

// The only case that triggers a restart: adapter present, base monitors up,
// but fewer than expected displays, and cooldown expired.
assert(decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: true,
                 displays: 2, expected: 3, base: 2) == .restart,
       "2/3 displays + adapter present + no cooldown → restart")

print("")
print("=== Guards that prevent restart ===")

assert(decideFix(secsSinceLastFix: 5, cooldown: 30, adapterPresent: true,
                 displays: 2, expected: 3, base: 2) == .skip("cooldown"),
       "Within cooldown → no restart")

assert(decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: false,
                 displays: 2, expected: 3, base: 2) == .skip("no-adapter"),
       "Adapter absent (outlet off) → no restart")

assert(decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: true,
                 displays: 3, expected: 3, base: 2) == .skip("displays-ok"),
       "All displays up → no restart")

assert(decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: true,
                 displays: 1, expected: 3, base: 2) == .skip("base-not-ready"),
       "Only 1 base monitor → no restart (TB still booting)")

assert(decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: true,
                 displays: 0, expected: 3, base: 2) == .skip("base-not-ready"),
       "Zero displays → no restart")

print("")
print("=== Guard priority order ===")
// Cooldown is checked first — even if adapter is missing, cooldown wins.
// This matters because IOKit lookup is more expensive than a date comparison.

assert(decideFix(secsSinceLastFix: 5, cooldown: 30, adapterPresent: false,
                 displays: 2, expected: 3, base: 2) == .skip("cooldown"),
       "Cooldown checked before adapter (cheapest check first)")

print("")
print("=== Cooldown boundary behavior ===")

assert(decideFix(secsSinceLastFix: 29.99, cooldown: 30, adapterPresent: true,
                 displays: 2, expected: 3, base: 2) == .skip("cooldown"),
       "Just under cooldown → still blocked")

assert(decideFix(secsSinceLastFix: 30, cooldown: 30, adapterPresent: true,
                 displays: 2, expected: 3, base: 2) == .restart,
       "Exactly at cooldown → proceeds (uses < not <=)")

assert(decideFix(secsSinceLastFix: 30.01, cooldown: 30, adapterPresent: true,
                 displays: 2, expected: 3, base: 2) == .restart,
       "Just past cooldown → proceeds")

print("")
print("=== Scenario: smart outlet power cycle ===")
// Simulates the real-world event sequence when the outlet turns on.
// Events arrive in order: USB attach → CG display 1 → CG display 2 → fix

var clock: TimeInterval = 0
var lastFix: TimeInterval = -9999

// Outlet on. Adapter enumerates first, monitors haven't negotiated yet.
var d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
                  displays: 0, expected: 3, base: 2)
assert(d == .skip("base-not-ready"), "T+0: USB attach, 0 displays → wait for TB")

// First TB monitor comes online
clock = 8
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 1, expected: 3, base: 2)
assert(d == .skip("base-not-ready"), "T+8: 1 TB monitor → still waiting")

// Second TB monitor comes online — this triggers the fix
clock = 12
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 2, expected: 3, base: 2)
assert(d == .restart, "T+12: 2 TB monitors → RESTART DisplayLink")
lastFix = clock

// Fix succeeded — 3 displays now. Spurious event during cooldown.
clock = 15
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 3, expected: 3, base: 2)
assert(d == .skip("cooldown"), "T+15: Fixed, within cooldown → skip")

// Well after cooldown, everything stable
clock = 300
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 3, expected: 3, base: 2)
assert(d == .skip("displays-ok"), "T+300: All good, past cooldown → skip")

print("")
print("=== Scenario: outlet off, daemon polls ===")
// When the outlet is off, the adapter isn't on USB. Poll should be a no-op.

d = decideFix(secsSinceLastFix: 9999, cooldown: 30, adapterPresent: false,
              displays: 0, expected: 3, base: 2)
assert(d == .skip("no-adapter"), "Outlet off: no adapter → no wasted restart")

print("")
print("=== Scenario: sleep/wake, no fix needed ===")
// On wake, everything comes back fine. Daemon should do nothing.

d = decideFix(secsSinceLastFix: 9999, cooldown: 30, adapterPresent: true,
              displays: 3, expected: 3, base: 2)
assert(d == .skip("displays-ok"), "Wake: all displays fine → no action")

print("")
print("=== Scenario: restart fails, retry behavior ===")
// After a failed restart, cooldown is NOT reset (stays set).
// The next event within cooldown should be blocked.

lastFix = 100  // restart attempted at T=100
clock = 110    // event at T=110, only 10s into 30s cooldown
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 2, expected: 3, base: 2)
assert(d == .skip("cooldown"), "After failed restart: cooldown prevents immediate retry")

clock = 131  // past cooldown
d = decideFix(secsSinceLastFix: clock - lastFix, cooldown: 30, adapterPresent: true,
              displays: 2, expected: 3, base: 2)
assert(d == .restart, "After cooldown expires: retry is allowed")

print("")
print("=== Edge: extra monitors (>expected) ===")

d = decideFix(secsSinceLastFix: 999, cooldown: 30, adapterPresent: true,
              displays: 4, expected: 3, base: 2)
assert(d == .skip("displays-ok"), "4 displays with 3 expected → no action (>= check)")

print("")
print("=========================================")
print("Results: \(passed) passed, \(failed) failed")
print("=========================================")
exit(failed > 0 ? 1 : 0)
