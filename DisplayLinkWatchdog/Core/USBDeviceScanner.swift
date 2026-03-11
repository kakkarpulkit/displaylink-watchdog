import Foundation
import IOKit
import IOKit.usb

// MARK: - Model

struct USBDevice: Identifiable, Hashable {
    let id           = UUID()
    let name:         String
    let manufacturer: String
    let vendorID:     Int
    let productID:    Int

    var vendorIDHex:  String { "0x\(String(vendorID,  radix: 16))" }
    var productIDHex: String { "0x\(String(productID, radix: 16))" }

    var displayName: String {
        let n = name.isEmpty ? "Unknown Device" : name
        return manufacturer.isEmpty ? n : "\(n) (\(manufacturer))"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(vendorID)
        hasher.combine(productID)
    }

    static func == (lhs: USBDevice, rhs: USBDevice) -> Bool {
        lhs.vendorID == rhs.vendorID && lhs.productID == rhs.productID
    }
}

// MARK: - Scanner

/// Scans the IOKit USB registry for DisplayLink devices.
/// Uses two strategies: known vendor ID first, then manufacturer-string fallback.
enum USBDeviceScanner {

    /// All known DisplayLink USB vendor IDs.
    private static let knownVendorIDs: [Int] = [0x17e9]

    static func findDisplayLinkDevices() -> [USBDevice] {
        var results: [USBDevice] = []

        // Strategy 1: match on the known DisplayLink vendor ID
        for vid in knownVendorIDs {
            let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
            matching[kUSBVendorID] = vid
            results += devicesMatching(matching as CFDictionary)
        }

        // Strategy 2: full USB bus scan filtered by manufacturer/product name
        if results.isEmpty {
            let matching = IOServiceMatching(kIOUSBDeviceClassName) as CFDictionary
            results = devicesMatching(matching).filter {
                $0.manufacturer.localizedCaseInsensitiveContains("displaylink") ||
                $0.name.localizedCaseInsensitiveContains("displaylink")
            }
        }

        return results
    }

    // MARK: - Private helpers

    private static func devicesMatching(_ matching: CFDictionary) -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDevice] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let dev = deviceInfo(from: service) {
                devices.append(dev)
            }
        }
        return devices
    }

    private static func deviceInfo(from service: io_object_t) -> USBDevice? {
        func stringProp(_ key: String) -> String {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? ""
        }
        func intProp(_ key: String) -> Int? {
            guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
            return v.intValue
        }

        guard let vid = intProp(kUSBVendorID),
              let pid = intProp(kUSBProductID) else { return nil }

        return USBDevice(
            name:         stringProp(kUSBProductString),
            manufacturer: stringProp(kUSBVendorString),
            vendorID:     vid,
            productID:    pid
        )
    }
}
