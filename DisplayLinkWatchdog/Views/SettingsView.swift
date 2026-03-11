import SwiftUI

/// Settings / Preferences window.
/// Allows the user to auto-detect their DisplayLink adapter, configure display
/// counts, and tune timing parameters.
struct SettingsView: View {

    @EnvironmentObject var engine: WatchdogEngine

    @State private var scannedDevices: [USBDevice] = []
    @State private var isScanning = false
    @State private var vendorIDText  = ""
    @State private var productIDText = ""

    var body: some View {
        Form {
            adapterSection
            displayCountSection
            timingSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 450)
        .onAppear {
            vendorIDText  = engine.config.vendorIDHex
            productIDText = engine.config.productIDHex
            scanForAdapters()
        }
    }

    // MARK: - Sections

    private var adapterSection: some View {
        Section {
            // Auto-detect row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let dev = selectedDevice {
                        Text(dev.displayName)
                            .fontWeight(.medium)
                        Text("\(dev.vendorIDHex)  /  \(dev.productIDHex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No adapter detected")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isScanning ? "Scanning…" : "Auto-Detect") {
                    scanForAdapters()
                }
                .disabled(isScanning)
            }

            // Picker only shown when multiple devices are found
            if scannedDevices.count > 1 {
                Picker("Detected adapters", selection: selectedDeviceBinding) {
                    Text("Custom / Manual").tag(nil as USBDevice?)
                    ForEach(scannedDevices) { dev in
                        Text(dev.displayName).tag(dev as USBDevice?)
                    }
                }
            }

            // Manual ID entry (always visible as a fallback)
            LabeledContent("Vendor ID") {
                TextField("0x17e9", text: $vendorIDText)
                    .frame(width: 90)
                    .onChange(of: vendorIDText) { newValue in
                        if let v = parseHex(newValue) { engine.config.vendorID = v }
                    }
            }
            LabeledContent("Product ID") {
                TextField("0x6000", text: $productIDText)
                    .frame(width: 90)
                    .onChange(of: productIDText) { newValue in
                        if let v = parseHex(newValue) { engine.config.productID = v }
                    }
            }

        } header: {
            Text("DisplayLink Adapter")
        } footer: {
            Text("Find your adapter's Vendor/Product ID with: system_profiler SPUSBDataType | grep -A5 DisplayLink")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displayCountSection: some View {
        Section("Display Configuration") {
            Stepper(
                "Expected displays: \(engine.config.expectedDisplays)",
                value: $engine.config.expectedDisplays,
                in: 1 ... 10
            )
            Stepper(
                "Base (non-DisplayLink) displays: \(engine.config.baseDisplays)",
                value: $engine.config.baseDisplays,
                in: 0 ... 9
            )
            Text(
                "Expected: total external monitors when everything is working. " +
                "Base: non-DisplayLink monitors that must be online before a fix is attempted " +
                "(prevents restarting the driver before your other monitors are ready)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            LabeledContent("Cooldown between fixes") {
                HStack {
                    TextField("30", value: $engine.config.cooldown, format: .number)
                        .frame(width: 60)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Fallback poll interval") {
                HStack {
                    TextField("300", value: $engine.config.pollInterval, format: .number)
                        .frame(width: 60)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            Text("The watchdog reacts instantly to USB and display events. Polling is a safety net for missed events.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Adapter binding

    private var selectedDevice: USBDevice? {
        scannedDevices.first {
            $0.vendorID == engine.config.vendorID && $0.productID == engine.config.productID
        }
    }

    private var selectedDeviceBinding: Binding<USBDevice?> {
        Binding(
            get: { selectedDevice },
            set: { dev in
                guard let dev else { return }
                engine.config.vendorID    = dev.vendorID
                engine.config.productID   = dev.productID
                engine.config.adapterName = dev.displayName
                vendorIDText  = dev.vendorIDHex
                productIDText = dev.productIDHex
            }
        )
    }

    // MARK: - Helpers

    private func scanForAdapters() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = USBDeviceScanner.findDisplayLinkDevices()
            DispatchQueue.main.async {
                scannedDevices = devices
                isScanning = false

                // Auto-select the only device if the user has never configured one
                if devices.count == 1 && engine.config.adapterName.isEmpty {
                    let dev = devices[0]
                    engine.config.vendorID    = dev.vendorID
                    engine.config.productID   = dev.productID
                    engine.config.adapterName = dev.displayName
                    vendorIDText  = dev.vendorIDHex
                    productIDText = dev.productIDHex
                }
            }
        }
    }

    private func parseHex(_ s: String) -> Int? {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = clean.hasPrefix("0x") || clean.hasPrefix("0X")
            ? String(clean.dropFirst(2)) : clean
        return Int(digits, radix: 16)
    }
}
