import Foundation
import CoreGraphics

// MARK: - C-compatible trampoline

/// Top-level function required for use as a CoreGraphics C callback.
private func cgDisplayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.contains(.addFlag), let ptr = userInfo else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(ptr).takeUnretainedValue().displayAdded()
}

// MARK: - DisplayWatcher

/// Registers a CoreGraphics reconfiguration callback and fires `onDisplayAdded`
/// whenever a display is added to the system.
final class DisplayWatcher {

    private let onDisplayAdded: () -> Void

    /// - Parameter onDisplayAdded: Called on whatever thread CG chooses (typically main).
    init(onDisplayAdded: @escaping () -> Void) {
        self.onDisplayAdded = onDisplayAdded
        // All stored properties are initialised above; `self` is fully available here.
        CGDisplayRegisterReconfigurationCallback(
            cgDisplayReconfigCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        // `passUnretained` is safe in deinit — the object is still in memory, just being torn down.
        // It produces the same address as at registration time, which is what CG needs to deregister.
        CGDisplayRemoveReconfigurationCallback(
            cgDisplayReconfigCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    fileprivate func displayAdded() {
        onDisplayAdded()
    }
}
