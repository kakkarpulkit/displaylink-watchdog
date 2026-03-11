import Foundation

/// Persisted configuration for the watchdog, backed by UserDefaults.
/// All keys share the `DLW_` prefix so they're recognisable in defaults exports.
final class WatchdogConfig: ObservableObject {

    // MARK: - Storage keys

    enum Keys {
        static let vendorID          = "DLW_VENDOR_ID"
        static let productID         = "DLW_PRODUCT_ID"
        static let expectedDisplays  = "DLW_EXPECTED"
        static let baseDisplays      = "DLW_BASE"
        static let cooldown          = "DLW_COOLDOWN"
        static let pollInterval      = "DLW_POLL_INTERVAL"
        static let adapterName       = "DLW_ADAPTER_NAME"
        static let launchAtLogin     = "DLW_LAUNCH_AT_LOGIN"
        static let hasCompletedSetup = "DLW_SETUP_DONE"
    }

    // MARK: - Published properties

    @Published var vendorID: Int = 0x17e9 {
        didSet { defaults.set(vendorID, forKey: Keys.vendorID) }
    }
    @Published var productID: Int = 0x6000 {
        didSet { defaults.set(productID, forKey: Keys.productID) }
    }
    @Published var expectedDisplays: Int = 3 {
        didSet { defaults.set(expectedDisplays, forKey: Keys.expectedDisplays) }
    }
    @Published var baseDisplays: Int = 2 {
        didSet { defaults.set(baseDisplays, forKey: Keys.baseDisplays) }
    }
    @Published var cooldown: TimeInterval = 30 {
        didSet { defaults.set(cooldown, forKey: Keys.cooldown) }
    }
    @Published var pollInterval: TimeInterval = 300 {
        didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) }
    }
    @Published var adapterName: String = "" {
        didSet { defaults.set(adapterName, forKey: Keys.adapterName) }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var hasCompletedSetup: Bool = false {
        didSet { defaults.set(hasCompletedSetup, forKey: Keys.hasCompletedSetup) }
    }

    // MARK: - Computed helpers

    var vendorIDHex: String  { "0x\(String(vendorID,  radix: 16))" }
    var productIDHex: String { "0x\(String(productID, radix: 16))" }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Private

    private let defaults: UserDefaults

    private func load() {
        vendorID          = int(Keys.vendorID,          fallback: 0x17e9)
        productID         = int(Keys.productID,         fallback: 0x6000)
        expectedDisplays  = int(Keys.expectedDisplays,  fallback: 3)
        baseDisplays      = int(Keys.baseDisplays,      fallback: 2)
        cooldown          = double(Keys.cooldown,        fallback: 30)
        pollInterval      = double(Keys.pollInterval,    fallback: 300)
        adapterName       = defaults.string(forKey: Keys.adapterName) ?? ""
        launchAtLogin     = defaults.bool(forKey: Keys.launchAtLogin)
        hasCompletedSetup = defaults.bool(forKey: Keys.hasCompletedSetup)
    }

    private func int(_ key: String, fallback: Int) -> Int {
        defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : fallback
    }

    private func double(_ key: String, fallback: Double) -> Double {
        defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : fallback
    }
}
