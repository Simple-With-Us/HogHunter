import AppKit
import SwiftUI

/// The Settings window.  Every control writes the same UserDefaults key the
/// store reads, so a change here reaches the panel on the next run loop turn
/// without either side owning the other.
struct SettingsView: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.appearance) private var appearance = AppearanceChoice.light.rawValue

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            AlertsSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("Alerts", systemImage: "bell")
                }
                .tag("alerts")

            IPhoneSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("iPhone", systemImage: "iphone")
                }
                .tag("iphone")

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag("about")
        }
        .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.colorScheme ?? .light)
        .background(WindowActivator())
        .onAppear { WindowActivator.front() }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.refreshInterval) private var refreshInterval: Double = 3
    @AppStorage(HogStore.Key.menuBarLabelMode) private var menuBarLabelMode = MenuBarLabelMode.machinePercent.rawValue
    @AppStorage(HogStore.Key.cpuScale) private var cpuScale = CpuScale.perCore.rawValue
    @AppStorage(HogStore.Key.appearance) private var appearance = AppearanceChoice.light.rawValue

    var body: some View {
        Form {
            Section("Sampling & Display") {
                Picker("Refresh Every", selection: $refreshInterval) {
                    Text("2 Seconds").tag(2.0)
                    Text("3 Seconds").tag(3.0)
                    Text("5 Seconds").tag(5.0)
                    Text("10 Seconds").tag(10.0)
                    Text("15 Seconds").tag(15.0)
                }

                Picker("Menu Bar Shows", selection: $menuBarLabelMode) {
                    ForEach(MenuBarLabelMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }

                Picker("CPU Scale", selection: $cpuScale) {
                    ForEach(CpuScale.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text(scaleExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Light is the default.  System follows the Mac's own setting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The same name the panel's footer and the coverage note use.
                    Toggle("Launch at Login", isOn: Binding(
                        get: { store.launchesAtLogin },
                        set: { _ in store.toggleLoginItem() }
                    ))
                    if let error = store.loginItemError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("History only covers the time Hog Hunter has been running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private var scaleExplanation: String {
        switch CpuScale(rawValue: cpuScale) ?? .perCore {
        case .perCore:
            return "Per Core matches Activity Monitor: 100% is one core fully busy, so a row can read 400%."
        case .machineShare:
            return "Share of Machine puts rows on the header's scale: 100% is every core fully busy."
        }
    }
}

// MARK: - Alerts Tab

private struct AlertsSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.alertsEnabled) private var alertsEnabled = false
    @AppStorage(HogStore.Key.alertThresholdPercent) private var alertThreshold: Double = 300
    @AppStorage(HogStore.Key.alertSustainedMinutes) private var alertSustainedMinutes: Int = 5

    var body: some View {
        Form {
            AlertsSection(
                alerts: store.alerts,
                enabled: $alertsEnabled,
                threshold: $alertThreshold,
                sustainedMinutes: $alertSustainedMinutes
            )
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}

// MARK: - iPhone Tab

private struct IPhoneSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    var body: some View {
        Form {
            Section("iPhone") {
                Toggle("Share With iPhone", isOn: $store.shareWithIPhone)
                Text("The Hog Hunter iPhone app can see this list while both are on the same Wi-Fi.  It cannot quit anything.  Turn this off on a network you do not trust.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.shareWithIPhone {
                    LabeledContent("Pairing Code") {
                        Text(spacedCode(store.companionCode))
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(store.companionStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Code") { copyCompanionCode() }
                        Button("New Code") { store.regenerateCompanionCode() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private func spacedCode(_ code: String) -> String {
        guard code.count > 4 else { return code }
        let split = code.index(code.startIndex, offsetBy: 4)
        return "\(code[..<split]) \(code[split...])"
    }

    private func copyCompanionCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.companionCode, forType: .string)
    }
}

// MARK: - About Tab

private struct AboutSettingsTab: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("About") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hog Hunter")
                            .font(.headline)
                        Text(SettingsView.versionString)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)

                Button("Open Activity Monitor") { HogActions.openActivityMonitor() }
                    .buttonStyle(.link)
                Button("Storage Window…") { HogActions.openStorageWindow(openWindow: openWindow) }
                    .buttonStyle(.link)
                Button("Network Window…") { HogActions.openNetworkWindow(openWindow: openWindow) }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}

// MARK: - Alerts

/// Its own view so it can observe `Alerts` directly and redraw when the
/// authorization answer comes back.
private struct AlertsSection: View {
    @ObservedObject var alerts: Alerts
    @Binding var enabled: Bool
    @Binding var threshold: Double
    @Binding var sustainedMinutes: Int

    var body: some View {
        Section("Alerts") {
            Toggle("Notify Me About Sustained Hogs", isOn: $enabled)

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $threshold, in: 100...1000, step: 50) {
                    Text("CPU Above")
                } minimumValueLabel: {
                    Text("100%")
                } maximumValueLabel: {
                    Text("1000%")
                }
                Text(thresholdExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Stepper(value: $sustainedMinutes, in: 1...30) {
                Text("For \(sustainedMinutes) \(sustainedMinutes == 1 ? "minute" : "minutes")")
            }
            .disabled(!enabled)

            if enabled, alerts.authorizationDenied {
                Text("Notifications are off for Hog Hunter in System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The threshold is always stated on the per-core scale, whatever the rows
    /// are showing, because that is the number the alert compares against.
    private var thresholdExplanation: String {
        let cores = threshold / 100
        let coreText = cores == cores.rounded()
            ? String(format: "%.0f", cores)
            : String(format: "%.1f", cores)
        let plural = cores == 1 ? "core" : "cores"
        return "\(HogFormat.cpu(threshold)) of one core — about \(coreText) \(plural) fully busy."
    }
}

// MARK: - Window activation
