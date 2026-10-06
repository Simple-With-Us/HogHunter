import AppKit
import SwiftUI

/// The Settings window.  Every control writes the same UserDefaults key the
/// store reads, so a change here reaches the panel on the next run loop turn
/// without either side owning the other.
struct SettingsView: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.appearance) private var appearance = AppearanceChoice.system.rawValue

    /// Settings opens on General every time.  Held as state rather than left to
    /// the scene's implicit default so the tab the window comes back to is a
    /// decision, not whatever was clicked last.
    @State private var selection = SettingsTab.general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Quit lives in the content, not the window's toolbar.  A SwiftUI
            // Settings scene spends its whole title bar on the tab strip, so a
            // toolbar item here does not render as a button at all -- it falls
            // into the toolbar's overflow chevron, which is the one place a
            // button asking you to quit an app has no business hiding in.
            HStack {
                Spacer(minLength: 0)
                // No Cmd-Q here.  Claiming the app-wide quit shortcut inside a
                // settings window silently swallows it everywhere else in the
                // app, which is a much worse bug than the one it was papering
                // over.
                Button("Quit Hog Hunter") { NSApp.terminate(nil) }
                    .help("Quit Hog Hunter")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            TabView(selection: $selection) {
            GeneralSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            AlertsSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("Alerts", systemImage: "bell")
                }
                .tag(SettingsTab.alerts)

            StartupSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("Startup", systemImage: "power")
                }
                .tag(SettingsTab.startup)

            ThemeSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("Theme", systemImage: "paintbrush")
                }
                .tag(SettingsTab.theme)

            CleanerSettingsTab()
                .tabItem {
                    Label("Cleaner", systemImage: "sparkles")
                }
                .tag(SettingsTab.cleaner)

            IPhoneSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("iPhone", systemImage: "iphone")
                }
                .tag(SettingsTab.iphone)

            AboutSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)

            AdvancedSettingsTab()
                .environmentObject(store)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
            }
            .padding(.top, 6)
        }
        .frame(width: SettingsView.windowWidth, height: SettingsView.windowHeight)
        // A stored value nobody recognises falls back to nil -- i.e. follow the Mac.
        .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.colorScheme)
        .background(WindowActivator(role: .settings))
        .onAppear { WindowActivator.front() }
    }

    /// Wide enough that eight tabs fit on one row without the labels truncating,
    /// and short enough that the shortest tab has no scroll bar.
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 430

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Selection identity for the Settings tabs.  Explicit rather than raw strings
/// so the default tab is written once and cannot drift out of sync with a tab.
enum SettingsTab: Hashable {
    case general, alerts, startup, theme, cleaner, iphone, about, advanced
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.refreshInterval) private var refreshInterval: Double = 3
    @AppStorage(HogStore.Key.menuBarLabelMode) private var menuBarLabelMode = MenuBarLabelMode.machinePercent.rawValue
    @AppStorage(HogStore.Key.cpuScale) private var cpuScale = CpuScale.perCore.rawValue

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

                Picker("CPU Rows Show", selection: $cpuScale) {
                    ForEach(CpuScale.allCases) {
                        Text($0.displayLabel(coreCount: store.pulse.coreCount)).tag($0.rawValue)
                    }
                }
                Text(scaleExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
    }

    private var scaleExplanation: String {
        let cores = max(1, store.pulse.coreCount)
        switch CpuScale(rawValue: cpuScale) ?? .perCore {
        case .perCore:
            return "Per Core matches Activity Monitor: 100% is one core fully busy, so one row can read \(100 * cores)%."
        case .machineShare:
            return "Per Machine divides every row by all \(cores) cores, so 100% means the whole machine and one row never exceeds 100%."
        }
    }
}

// MARK: - Startup Tab

private struct StartupSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    var body: some View {
        Form {
            Section("Startup") {
                // The same control the panel's footer used to carry, now with
                // room beside it to say what it does and to show a failure.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                Text("Hog Hunter opens with your Mac and samples in the background.  History only covers the time it has been running, so this is also what makes the Past Hour and Past 24 Hours views able to reach a full day.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
    }
}

// MARK: - Theme Tab

private struct ThemeSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.appearance) private var appearance = AppearanceChoice.system.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("System is the default, so Hog Hunter follows the Mac.  Light and Dark pin it either way, here and in the menu bar panel.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
    }
}

// MARK: - Alerts Tab

private struct AlertsSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.alertsEnabled) private var alertsEnabled = false
    @AppStorage(HogStore.Key.alertThresholdPercent) private var alertThreshold: Double = 300
    @AppStorage(HogStore.Key.alertSustainedMinutes) private var alertSustainedMinutes: Int = 5
    @AppStorage(HogStore.Key.alertWebhookURL) private var alertWebhookURL: String = ""

    var body: some View {
        Form {
            AlertsSection(
                alerts: store.alerts,
                enabled: $alertsEnabled,
                threshold: $alertThreshold,
                sustainedMinutes: $alertSustainedMinutes,
                webhookURL: $alertWebhookURL
            )
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
    }
}

// MARK: - Cleaner Tab

private struct CleanerSettingsTab: View {
    @State private var exclusions: CleanerExclusions = CleanerExclusions.load()

    var body: some View {
        Form {
            Section("Category Exclusions") {
                Text("Excluded categories are skipped during disk scans and will never be cleaned.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(CleanCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { exclusions.isCategoryExcluded(category) },
                        set: { isExcluded in
                            if isExcluded {
                                exclusions.excludedCategories.insert(category.rawValue)
                            } else {
                                exclusions.excludedCategories.remove(category.rawValue)
                            }
                            exclusions.save()
                        }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: category.icon)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(category.description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Custom Excluded Folders") {
                Text("Files in these directories or their subfolders are preserved and skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if exclusions.excludedPaths.isEmpty {
                    Text("No custom excluded folders.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(exclusions.excludedPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                exclusions.excludedPaths.removeAll { $0 == path }
                                exclusions.save()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove exclusion")
                        }
                    }
                }

                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Exclude Folder"
                    if panel.runModal() == .OK, let url = panel.url {
                        let path = (url.path as NSString).standardizingPath
                        if !exclusions.excludedPaths.contains(path) {
                            exclusions.excludedPaths.append(path)
                            exclusions.save()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
        .onAppear {
            exclusions = CleanerExclusions.load()
        }
    }
}

// MARK: - iPhone Tab

private struct IPhoneSettingsTab: View {
    @EnvironmentObject private var store: HogStore

    var body: some View {
        Form {
            Section("iPhone") {
                Toggle("Share With iPhone", isOn: $store.shareWithIPhone)
                Text("The Hog Hunter iPhone app can see this list on the same Wi-Fi, or from anywhere over Tailscale.  Quitting, taming, and cleaning each need the opt-ins below.  Turn this off on a network you do not trust.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.shareWithIPhone {
                    LabeledContent("Pairing Code") {
                        PairingCodeField(
                            code: spacedCode(store.companionCode),
                            rawCode: store.companionCode
                        )
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

            if store.shareWithIPhone {
                Section("Remote Control") {
                    Toggle("Allow iPhone to Quit or Tame Apps & Processes", isOn: $store.allowRemoteQuit)
                    Text("When enabled, the paired iPhone can quit, force quit, or tame user-owned apps.  The phone asks you to confirm each one.  System-critical processes and other users' processes are always protected.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Allow iPhone to Run Disk Cleaner", isOn: $store.allowRemoteClean)
                    Text("When enabled, the paired iPhone can start a Standard clean.  A local snapshot is taken first and items go to the Trash.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A phone without the code can ask to pair.  This Mac then shows an alert where you can allow it and pick these same two choices.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Remote Access (Tailscale / Domain)") {
                    let addresses = CompanionServer.detectHostAddresses()
                    LabeledContent("Port") {
                        Text("\(store.companionPort)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let ts = addresses.tailscaleIP {
                        LabeledContent("Tailscale IP") {
                            Text(ts)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let loc = addresses.localIP {
                        LabeledContent("Local Wi-Fi IP") {
                            Text(loc)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Text("Away from this Wi-Fi: Connect via Tailscale using your Tailscale IP or MagicDNS hostname, or forward port \(store.companionPort) on your domain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
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

private struct PairingCodeField: View {
    let code: String
    let rawCode: String
    @State private var isHovering = false
    @State private var justCopied = false
    /// Pending "Copied" reset, cancelled on a re-click so only the newest click
    /// controls the badge.
    @State private var copyResetTask: Task<Void, Never>?
    @State private var cursorPushed = false

    var body: some View {
        Button(action: copyToClipboard) {
            HStack(spacing: 8) {
                Text(code)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.primary)

                if justCopied {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Copied")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if isHovering {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Click to copy")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering || justCopied ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering {
                if !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                }
            } else {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .help(justCopied ? "Copied" : "Click to copy")
        .accessibilityLabel("Pairing Code \(code)")
        .accessibilityHint(justCopied ? "Copied to clipboard" : "Click to copy pairing code to clipboard")
    }

    private func copyToClipboard() {
        //  A second click inside the window must own the whole window: cancel the
        //  pending reset first, or the first click's timer clears "Copied" early.
        copyResetTask?.cancel()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawCode, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            justCopied = true
        }
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }
}

// MARK: - About Tab

private struct AboutSettingsTab: View {
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

                // Storage and Network are tabs of the menu bar panel now, not
                // windows of their own, so there is nothing to link to.
                Button("Open Activity Monitor") { HogActions.openActivityMonitor() }
                    .buttonStyle(.link)
                Text("Storage and Network are tabs in the menu bar panel.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
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
    @Binding var webhookURL: String

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

        Section("Webhooks & Pushover") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Webhook URL (Slack, Discord, Pushover, generic)", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
                Text("Sends a JSON alert payload when a sustained hog triggers.  Compatible with Slack, Discord, Pushover, and custom HTTP endpoints.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Send Test Webhook") {
                        alerts.sendTestWebhook(to: webhookURL)
                    }
                    .disabled(webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let status = alerts.lastWebhookStatus {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(status.hasPrefix("Delivered") ? Color.secondary : Color.red)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
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

// MARK: - Advanced Tab

/// The admin surface for the Infisical source of truth.  Hog Hunter is a
/// single-user local app, so the local user IS the admin and this gate is
/// that fact made visible, not a parallel auth system.  See INFISICAL.md.
private struct AdvancedSettingsTab: View {
    @EnvironmentObject private var store: HogStore
    @ObservedObject private var infisical = InfisicalSettings.shared

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var projectId = InfisicalSettings.shared.projectId
    @State private var notice: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Infisical Settings Sync") {
                Text("App-level settings sync from Infisical, the fleet's source of truth.  The credential below is stored in the Keychain, never in the app or its files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Status")
                    Spacer()
                    Text(infisical.isConfigured ? "Configured" : "Not Configured")
                        .foregroundStyle(infisical.isConfigured ? .green : .secondary)
                }
                if let last = infisical.lastRefresh {
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        Text(last, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = infisical.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Credential") {
                TextField("Client ID", text: $clientId)
                    .disabled(isWorking || infisical.isSaving)
                SecureField("Client Secret", text: $clientSecret)
                    .disabled(isWorking || infisical.isSaving)
                TextField("Project ID", text: $projectId)
                    .disabled(isWorking || infisical.isSaving)
                Text("Uses the dev environment.  The connection is checked before replacing your saved setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save to Keychain") { saveCredential() }
                        .disabled(clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UUID(uuidString: projectId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || isWorking || infisical.isSaving)
                    Button("Clear") { clearCredential() }
                        .disabled(!infisical.isConfigured || isWorking)
                    Spacer()
                    Button("Sync Now") { syncNow() }
                        .disabled(!infisical.isConfigured || infisical.isRefreshing || infisical.isSaving || isWorking)
                }
            }

            Section("Seed") {
                Text("Push the current local values of the migrated settings to Infisical.  Secrets are never pushed from here; fill those in the Infisical dashboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Push Current Values to Infisical") { pushCurrent() }
                    .disabled(!infisical.isConfigured || isWorking)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.windowWidth - 80)
        .onChange(of: infisical.projectId) { previous, current in
            // Bootstrap may finish after this tab first appears.  Update only
            // an untouched field; never replace a project the admin is typing.
            if projectId == previous { projectId = current }
        }
    }

    private func saveCredential() {
        notice = nil
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await infisical.saveCredential(clientId: clientId, clientSecret: clientSecret, projectId: projectId)
                clientSecret = ""
                notice = "Connection verified and saved to the Keychain."
            } catch {
                notice = "Save failed: \(InfisicalSettings.safeMessage(for: error))"
            }
        }
    }

    private func clearCredential() {
        do {
            try infisical.clearCredential()
        } catch {
            notice = "Clear failed: \(InfisicalSettings.safeMessage(for: error))"
            return
        }
        projectId = infisical.projectId
        clientId = ""
        clientSecret = ""
        notice = "Credential removed.  Local defaults stand until a credential is saved again."
    }

    private func syncNow() {
        Task { @MainActor in
            await infisical.refresh()
        }
    }

    private func pushCurrent() {
        notice = nil
        isWorking = true
        let expectedGeneration = infisical.connectionGeneration
        Task { @MainActor in
            defer { isWorking = false }
            do {
                // Live values for the knobs the store owns; shipped defaults
                // for the rest.  alertWebhookURL is a secret and is never
                // pushed from here.
                var values = InfisicalDefaults.values
                values[InfisicalKey.refreshInterval] = String(store.refreshInterval)
                values[InfisicalKey.alertThresholdPercent] = String(store.alertThresholdPercent)
                values[InfisicalKey.alertSustainedMinutes] = String(store.alertSustainedMinutes)
                for (key, value) in values {
                    try await infisical.set(value, forKey: key, expectedGeneration: expectedGeneration)
                }
                await infisical.refresh()
                guard infisical.connectionGeneration == expectedGeneration else { throw InfisicalError.configurationChanged }
                notice = "Pushed \(values.count) settings to Infisical."
            } catch {
                notice = "Push failed: \(InfisicalSettings.safeMessage(for: error))"
            }
        }
    }
}
