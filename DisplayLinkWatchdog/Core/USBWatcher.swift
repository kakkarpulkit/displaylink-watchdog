import Foundation
import IOKit
import IOKit.usb

// MARK: - C-compatible trampoline

/// Top-level function required for use as an IOKit C callback.
private func usbDeviceAddedCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ iterator: io_iterator_t
) {
    // Drain the iterator — required by IOKit to reset it
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
        IOObjectRelease(service)
    }
    guard let ptr = refcon else { return }
    Unmanaged<USBWatcher>.fromOpaque(ptr).takeUnretainedValue().deviceAdded()
}

// MARK: - USBWatcher

/// Watches for a specific USB device (by vendor/product ID) and fires a callback
/// on the main run loop when the device appears.
final class USBWatcher {

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private let onAdded: () -> Void

    /// - Parameters:
    ///   - vendorID:  USB vendor ID to match (e.g. 0x17e9 for DisplayLink)
    ///   - productID: USB product ID to match
    ///   - onAdded:   Called on the main thread when the device appears.
    init(vendorID: Int, productID: Int, onAdded: @escaping () -> Void) {
        self.onAdded = onAdded
        startWatching(vendorID: vendorID, productID: productID)
    }

    deinit {
        stop()
    }

    func stop() {
        if addedIterator != IO_OBJECT_NULL {
            IOObjectRelease(addedIterator)
            addedIterator = IO_OBJECT_NULL
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    fileprivate func deviceAdded() {
        onAdded()
    }

    // MARK: - Private

    private func startWatching(vendorID: Int, productID: Int) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port

        // Add the notification source to the main run loop so callbacks arrive on the main thread
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID]  = vendorID
        matching[kUSBProductID] = productID

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching as CFDictionary,
            usbDeviceAddedCallback,
            selfPtr,
            &addedIterator
        )

        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            notifyPort = nil
            return
        }

        // Drain pre-existing matches; IOKit fires for currently-connected devices at registration time.
        // We do NOT call the callback for these — the WatchdogEngine does a startup check separately.
        while case let service = IOIteratorNext(addedIterator), service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }
}
