import SwiftUI

enum CompanionTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case storage = "Storage"
    case network = "Network"
    var id: String { rawValue }
}

enum CompanionSort: String, CaseIterable, Identifiable {
    case cpu = "CPU %"
    case memory = "Memory"
    var id: String { rawValue }
}

/// Live read of the iPhone's own storage volume, used by the iOS Storage
/// tab alongside the existing Mac-disk section.  Pulls once via
/// `URL.resourceValues(forKeys:)`, which works inside the iOS sandbox without
/// any extra entitlement because `/` is the app's own sandbox root.
struct iPhoneStorageSummary: Equatable {
    var name: String
    var totalBytes: UInt64
    var freeBytes: UInt64
    var usedPercent: Double
    var usedText: String
    var freeText: String
}

enum iPhoneStorage {
    /// Reads the current iPhone storage summary, or nil if the kernel
    /// cannot answer (very rare on iOS, but the sim can return nil values).
    static func summary() -> iPhoneStorageSummary? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeLocalizedNameKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // iOS gives back Int64 for capacity values; promote to UInt64 here
        // so the call site can do math without overflow concerns.
        guard let totalInt = values.volumeTotalCapacity else { return nil }
        guard let freeInt = values.volumeAvailableCapacity else { return nil }
        let totalBytes = UInt64(max(0, totalInt))
        let freeBytes = UInt64(max(0, freeInt))
        guard freeBytes <= totalBytes, totalBytes > 0 else { return nil }
        let used = totalBytes - freeBytes
        let usedPercent = totalBytes > 0 ? (Double(used) / Double(totalBytes)) * 100 : 0
        return iPhoneStorageSummary(
            name: values.volumeLocalizedName ?? "iPhone Storage",
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            usedPercent: usedPercent,
            usedText: iPhoneStorage.format(bytes: used),
            freeText: iPhoneStorage.format(bytes: freeBytes)
        )
    }

    /// Locale-pinned binary units, matching the Mac pane's HogFormat.memory so
    /// "1.5 GB" reads the same on both sides regardless of region.
    static func format(bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        let kb = Double(bytes) / 1024
        let posix = Locale(identifier: "en_US_POSIX")
        if mb >= 1023.5 { return String(format: "%.1f GB", locale: posix, gb) }
        if kb >= 1023.5 { return String(format: "%.0f MB", locale: posix, mb) }
        return String(format: "%.0f KB", locale: posix, kb)
    }
}

enum UsageParser {
    static func parseCPU(_ text: String) -> Double {
        let digits = text.filter { $0.isNumber || $0 == "." }
        return Double(digits) ?? 0.0
    }

    static func parseMemoryBytes(_ text: String) -> UInt64 {
        let upper = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let numPart = upper.filter { $0.isNumber || $0 == "." }
        guard let val = Double(numPart) else { return 0 }
        if upper.contains("TB") {
            return UInt64(val * 1_099_511_627_776)
        } else if upper.contains("GB") {
            return UInt64(val * 1_073_741_824)
        } else if upper.contains("MB") {
            return UInt64(val * 1_048_576)
        } else if upper.contains("KB") {
            return UInt64(val * 1_024)
        } else {
            return UInt64(val)
        }
    }
}

extension CompanionRow {
    var sortCPU: Double {
        cpuPercent ?? UsageParser.parseCPU(cpuText)
    }

    var sortMemory: UInt64 {
        memoryBytes ?? UsageParser.parseMemoryBytes(memoryText)
    }
}

struct CompanionRootView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Hog Hunter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.remoteHostDraft = model.saved?.remoteHost ?? ""
                            model.remotePortDraft = "\(model.saved?.remotePort ?? 24240)"
                            model.remoteTokenDraft = model.saved?.token ?? ""
                            model.remoteNameDraft = model.saved?.name ?? ""
                            model.remoteConnectError = nil
                            model.isRemoteSheetPresented = true
                        } label: {
                            Image(systemName: "network.badge.shield.half.filled")
                        }
                        .accessibilityLabel("Connect Remotely")
                    }
                    if model.saved != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { model.showForgetConfirm = true } label: {
                                Image(systemName: "link")
                            }
                            .accessibilityLabel("Forget Mac")
                        }
                    }
                }
        }
        .onAppear { model.start() }
        .alert("Forget \(model.saved?.name ?? "This Mac")?", isPresented: $model.showForgetConfirm) {
            Button("Forget Mac", role: .destructive) { model.forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will stop showing it until you pair again.")
        }
        .sheet(isPresented: codePresented) {
            CodeEntryView(model: model)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $model.isRemoteSheetPresented) {
            RemoteConnectSheet(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    private var codePresented: Binding<Bool> {
        Binding(
            get: { if case .code = model.phase { return true } else { return false } },
            set: { if !$0 { model.cancelCode() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .live:
            if let snapshot = model.snapshot {
                DashboardView(snapshot: snapshot, model: model)
            } else {
                StatusPage(
                    title: "Waiting for a Snapshot",
                    message: "Hog Hunter is connected and waiting for the next sample from your Mac."
                )
            }
        case .choose:
            MacListView(model: model)
        case .offline:
            StatusPage(
                title: "Mac Offline or Not Found",
                message: model.statusLine + "  Hog Hunter shares while the Mac app is open and Share With iPhone is on.  Off Wi-Fi or remote?  Tap below to connect via Tailscale or your Mac's IP/domain on port \(CompanionModel.defaultPort).",
                isOnWiFi: model.isOnWiFi,
                onRemoteConnect: {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                },
                onDemoMode: {
                    model.enterDemoMode()
                }
            )
        case .looking, .code:
            StatusPage(
                title: "Looking for Your Mac",
                message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.  Both devices need the same Wi-Fi, or connect via Tailscale.  Off Wi-Fi?  Tap below to enter your Mac's Tailscale name (e.g. my-mac.tailnet.ts.net) or IP on port \(CompanionModel.defaultPort).",
                isOnWiFi: model.isOnWiFi,
                onRemoteConnect: {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                },
                onDemoMode: {
                    model.enterDemoMode()
                }
            )
        }
    }
}

private struct StatusPage: View {
    let title: String
    let message: String
    var isOnWiFi: Bool = true
    var onRemoteConnect: (() -> Void)? = nil
    var onDemoMode: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !isOnWiFi, onRemoteConnect != nil {
                VStack(spacing: 6) {
                    Label("This iPhone is not on Wi-Fi", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.semibold))
                    Text("Do you use Tailscale or another route to your Mac?  Connect by address on port \(CompanionModel.defaultPort).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
            }

            if onRemoteConnect != nil || onDemoMode != nil {
                VStack(spacing: 10) {
                    if let onRemoteConnect {
                        Button(action: onRemoteConnect) {
                            Label("Connect by Tailscale or Address…", systemImage: "network")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let onDemoMode {
                        Button(action: onDemoMode) {
                            Label("Explore Demo Mode (App Review)", systemImage: "sparkles")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct MacListView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        List {
            Section("Nearby Macs") {
                ForEach(model.discovered) { mac in
                    Button {
                        model.select(mac)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Share With iPhone is on")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    model.remoteConnectError = nil
                    model.isRemoteSheetPresented = true
                } label: {
                    Label("Connect by Tailscale or Address…", systemImage: "network")
                }
            }
        }
        .overlay {
            if model.discovered.isEmpty {
                StatusPage(
                    title: "Looking for Your Mac",
                    message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.",
                    isOnWiFi: model.isOnWiFi,
                    onRemoteConnect: {
                        model.remoteConnectError = nil
                        model.isRemoteSheetPresented = true
                    },
                    onDemoMode: {
                        model.enterDemoMode()
                    }
                )
            }
        }
    }
}

private struct CodeEntryView: View {
    @Bindable var model: CompanionModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing Code") {
                    TextField("Code", text: $model.codeDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                        .focused($focused)
                    Text("Type the code shown in Hog Hunter Settings > iPhone on your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await model.requestApproval() }
                    } label: {
                        HStack {
                            Label(model.isWaitingForApproval ? "Check Your Mac and Click Allow" : "Ask Mac to Approve Instead", systemImage: "desktopcomputer")
                            Spacer()
                            if model.isWaitingForApproval { ProgressView() }
                        }
                    }
                    .disabled(model.isWaitingForApproval || model.isSubmittingCode)
                } footer: {
                    Text("No code needed.  Your Mac shows an alert where you allow this iPhone and choose whether it can quit apps or run the disk cleaner.")
                }
                if let codeError = model.codeError {
                    Section {
                        Text(codeError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelCode() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { Task { await model.submitCode() } }
                        .disabled(model.isSubmittingCode)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// The result of one Sample for 3 Seconds, held as one value so a late reply
/// cannot be shown under another row's name.
struct SampleOutcome: Identifiable {
    let id = UUID()
    let response: CompanionSampleResponse
}

struct DashboardView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var selectedTab: CompanionTab = ProcessInfo.processInfo.arguments.contains("-HogHunterStorage") ? .storage : (ProcessInfo.processInfo.arguments.contains("-HogHunterNetwork") ? .network : .activity)
    @State private var sortOrder: CompanionSort = .cpu
    @State private var sortAscending: Bool = false
    @State private var showCleanConfirm = false
    @State private var pendingQuitRow: CompanionRow?
    @State private var isForceQuit = false
    @State private var showQuitConfirm = false
    @State private var lastQuitResult: CompanionQuitResponse?
    @State private var showQuitResultAlert = false
    @State private var pendingTameRow: CompanionRow?
    @State private var pendingTameAction = "tame"
    /// Action and result land as ONE value.  Holding them in separate `@State`
    /// let two in-flight tasks interleave, so a stale response could label a tame
    /// failure "Could Not Restore Priority" (or the reverse).
    @State private var lastTameOutcome: (action: String, result: CompanionTameResponse)?
    @State private var showTameConfirm = false
    @State private var showTameResultAlert = false
    @State private var showAddPathAlert = false
    @State private var newPathInput = ""
    // The screenshot lane launches the app with these flags to put each new
    // surface on screen (scripts/capture-app-screenshots.sh); nothing else sets them.
    @State private var showMacSettings = ProcessInfo.processInfo.arguments.contains("-HogHunterMacSettings")
    @State private var showVacuum = ProcessInfo.processInfo.arguments.contains("-HogHunterVacuum")
    @State private var showCleaner = ProcessInfo.processInfo.arguments.contains("-HogHunterCleaner")
        || ProcessInfo.processInfo.arguments.contains("-HogHunterCleanerExtreme")
    @State private var sampleOutcome: SampleOutcome? = ProcessInfo.processInfo.arguments.contains("-HogHunterSampleResult")
        ? SampleOutcome(response: CompanionModel.sampleSampleResponse(name: "Google Chrome", rowId: 1042))
        : nil
    /// A sample that finished while the Mac Settings sheet was open; shown when it closes.
    @State private var queuedSampleOutcome: SampleOutcome?
    @State private var pendingSampleRow: CompanionRow?
    @State private var showSampleConfirm = false

    private func confirmQuit(row: CompanionRow, force: Bool) {
        pendingQuitRow = row
        isForceQuit = force
        showQuitConfirm = true
    }

    private func confirmTame(row: CompanionRow, action: String) {
        pendingTameRow = row
        pendingTameAction = action
        showTameConfirm = true
    }

    /// Exclusion and view changes exist only when the Mac owner turned them on.
    private var canEdit: Bool { snapshot.remoteEditAllowed == true }

    /// The CPU rows' scale as the Mac reports it ("Per Core" or "Share of Machine").
    private var isMachineScale: Bool {
        let scale = snapshot.cpuScale.lowercased()
        return scale.contains("machine") || scale.contains("share")
    }

    /// Cores the Per Machine scale divides by.  An older Mac sends only the
    /// caption ("of all 10 cores").
    private var coreCount: Int {
        if let cores = snapshot.pulse.coreCount, cores > 0 { return cores }
        let digits = snapshot.pulse.cpuCaption.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        return max(1, digits ?? 1)
    }

    /// The same words Settings > General shows on the Mac.
    private var scaleExplanation: String {
        if isMachineScale {
            return "Per Machine divides every row by all \(coreCount) cores, so 100% means the whole machine and one row never exceeds 100%."
        }
        return "Per Core matches Activity Monitor: 100% is one core fully busy, so one row can read \(100 * coreCount)%."
    }

    private static let editOffNote = "Changing exclusions and the Mac's view from iPhone is off.\u{00A0} Turn on Allow iPhone to Change Exclusions & View in Hog Hunter Settings > iPhone on your Mac."

    private var sortedRows: [CompanionRow] {
        let sorted = snapshot.rows.sorted(by: { a, b in
            switch sortOrder {
            case .cpu:
                let aCpu = a.sortCPU
                let bCpu = b.sortCPU
                if abs(aCpu - bCpu) < 0.05 {
                    if a.sortMemory != b.sortMemory {
                        return a.sortMemory > b.sortMemory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return aCpu > bCpu
            case .memory:
                let aMemStr = a.memoryText
                let bMemStr = b.memoryText
                if aMemStr == bMemStr {
                    if abs(a.sortCPU - b.sortCPU) >= 0.05 {
                        return a.sortCPU > b.sortCPU
                    }
                    if a.sortMemory != b.sortMemory {
                        return a.sortMemory > b.sortMemory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return a.sortMemory > b.sortMemory
            }
        })
        return sortAscending ? sorted.reversed() : sorted
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isDemoMode {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Explore Demo Mode (App Review)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Exit Demo") {
                        model.exitDemoMode()
                    }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tap a tab to switch view.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.top, 6)
                Picker("Tab", selection: $selectedTab) {
                    ForEach(CompanionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            List {
                hostHeaderSection

                switch selectedTab {
                case .activity:
                    activityContent
                case .storage:
                    storageContent
                case .network:
                    networkContent
                }
            }
            .listStyle(.insetGrouped)
        }
        .confirmationDialog(
            "Clean \(snapshot.hostName)?",
            isPresented: $showCleanConfirm,
            titleVisibility: .visible
        ) {
            Button("Run Safe Clean", role: .destructive) {
                Task { await model.triggerRemoteClean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will safely trigger a Standard Clean on \(snapshot.hostName). An APFS local snapshot will be taken first, and deleted items are moved to Trash.")
        }
        .confirmationDialog(
            "\(isForceQuit ? "Force Quit" : "Quit") \(pendingQuitRow?.name ?? "App")?",
            isPresented: $showQuitConfirm,
            titleVisibility: .visible
        ) {
            Button(isForceQuit ? "Force Quit" : "Quit", role: .destructive) {
                if let row = pendingQuitRow, row.pid != nil {
                    Task {
                        let res = await model.quitProcess(row: row, force: isForceQuit)
                        lastQuitResult = res
                        showQuitResultAlert = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isForceQuit
                ? "Force quitting \(pendingQuitRow?.name ?? "this app") will terminate it immediately on \(snapshot.hostName).  Any unsaved work will be lost."
                : "Quitting \(pendingQuitRow?.name ?? "this app") will ask it to close gracefully on \(snapshot.hostName).")
        }
        .confirmationDialog(
            "\(pendingTameAction == "untame" ? "Restore Priority for" : "Tame") \(pendingTameRow?.name ?? "App")?",
            isPresented: $showTameConfirm,
            titleVisibility: .visible
        ) {
            Button(pendingTameAction == "untame" ? "Restore Priority" : "Tame App (Lower Priority)") {
                if let row = pendingTameRow, row.pid != nil {
                    let action = pendingTameAction
                    Task {
                        let res = await model.tameProcess(row: row, action: action)
                        lastTameOutcome = (action, res)
                        showTameResultAlert = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingTameAction == "untame"
                ? "Restores normal CPU scheduling priority for \(pendingTameRow?.name ?? "this app") on \(snapshot.hostName)."
                : "Lowers CPU priority (renices to +10) for \(pendingTameRow?.name ?? "this app") so it does not starve other apps on \(snapshot.hostName).")
        }
        .alert(
            lastTameOutcome?.result.error != nil
                ? (lastTameOutcome?.action == "untame" ? "Could Not Restore Priority" : "Could Not Tame App")
                : "Priority Updated",
            isPresented: $showTameResultAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = lastTameOutcome?.result.error {
                Text(error)
            } else if let message = lastTameOutcome?.result.message {
                Text(message)
            } else {
                Text("Command delivered to \(snapshot.hostName).")
            }
        }
        .alert(
            lastQuitResult?.error != nil ? "Could Not Quit" : "Quit Request Delivered",
            isPresented: $showQuitResultAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = lastQuitResult?.error {
                Text(error)
            } else if let message = lastQuitResult?.message {
                Text(message)
            } else {
                Text("Command delivered to \(snapshot.hostName).")
            }
        }
        .alert("Exclude Folder", isPresented: $showAddPathAlert) {
            TextField("Folder path (e.g. ~/Code/Project)", text: $newPathInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Exclude") {
                let p = newPathInput
                Task { await model.addExcludedPath(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a folder path on \(snapshot.hostName) to exclude from all disk cleaning.")
        }
        .alert(
            "The Mac Did Not Accept That",
            isPresented: Binding(
                get: { model.controlError != nil },
                set: { if !$0 { model.controlError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.controlError = nil }
        } message: {
            Text(model.controlError ?? "")
        }
        .onChange(of: model.showCleanDialogRequested) { _, requested in
            if requested {
                showCleanConfirm = true
                model.showCleanDialogRequested = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMacSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Mac Settings")
            }
        }
        .sheet(isPresented: $showMacSettings) {
            MacSettingsView(snapshot: snapshot, model: model)
        }
        .navigationDestination(isPresented: $showVacuum) {
            VacuumView(snapshot: snapshot, model: model)
        }
        .navigationDestination(isPresented: $showCleaner) {
            CleanerView(model: model)
        }
        .onChange(of: showMacSettings) { _, isOpen in
            if !isOpen, let queued = queuedSampleOutcome {
                queuedSampleOutcome = nil
                sampleOutcome = queued
            }
        }
        .confirmationDialog(
            "Sample \(pendingSampleRow?.name ?? "App")?",
            isPresented: $showSampleConfirm,
            titleVisibility: .visible
        ) {
            Button("Sample for 3 Seconds") {
                if let row = pendingSampleRow { runSample(row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(snapshot.hostName) will watch \(pendingSampleRow?.name ?? "this app") for 3 seconds and save a report in Logs/HogHunter on the Mac.\u{00A0} Nothing is changed or closed.")
        }
        .sheet(item: $sampleOutcome) { outcome in
            SampleResultView(response: outcome.response, hostName: snapshot.hostName)
                .presentationDetents([.medium, .large])
        }
    }

    private func confirmSample(_ row: CompanionRow) {
        pendingSampleRow = row
        showSampleConfirm = true
    }

    private func runSample(_ row: CompanionRow) {
        Task {
            let response = await model.sampleProcess(row: row)
            // One sheet at a time: hold the result until Mac Settings closes.
            if showMacSettings {
                queuedSampleOutcome = SampleOutcome(response: response)
            } else {
                sampleOutcome = SampleOutcome(response: response)
            }
        }
    }

    private var hostHeaderSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.hostName)
                        .font(.headline)
                    Text("\(snapshot.window) · \(snapshot.grouping) · \(snapshot.cpuScale)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.saved?.remoteHost != nil {
                    Label("Remote", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                MeterCard(
                    title: "CPU",
                    value: snapshot.pulse.cpuPercent,
                    headline: snapshot.pulse.cpuText,
                    caption: snapshot.pulse.cpuCaption,
                    severity: snapshot.pulse.cpuSeverity,
                    history: snapshot.cpuHistory
                )
                MeterCard(
                    title: "Memory",
                    value: snapshot.pulse.memoryPercent,
                    headline: snapshot.pulse.memoryText,
                    caption: snapshot.pulse.memoryCaption,
                    severity: snapshot.pulse.pressureSeverity
                )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if snapshot.pulse.swapText != nil || snapshot.pulse.pressureText != nil || snapshot.pulse.batteryText != nil || (snapshot.pulse.thermalState != nil && snapshot.pulse.thermalState != "nominal") {
                HStack(spacing: 8) {
                    if let swap = snapshot.pulse.swapText {
                        Pill(text: swap, severity: snapshot.pulse.pressureSeverity)
                    }
                    if let pressure = snapshot.pulse.pressureText {
                        Pill(text: pressure, severity: snapshot.pulse.pressureSeverity)
                    }
                    if let battery = snapshot.pulse.batteryText {
                        Pill(text: (snapshot.pulse.isCharging == true ? "⚡ " : "🔋 ") + battery, severity: "calm")
                    }
                    if let thermal = snapshot.pulse.thermalState, thermal != "nominal" {
                        Pill(text: "Thermal: \(thermal)", severity: (thermal == "critical" || thermal == "serious") ? "hot" : "elevated")
                    }
                }
            }
        }

        Section {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Lookback")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Picker("Window", selection: Binding(
                        get: {
                            let w = snapshot.window.lowercased()
                            if w.contains("24") || w.contains("day") { return "24h" }
                            if w.contains("1") || w.contains("hour") { return "1h" }
                            return "now"
                        },
                        set: { next in
                            let win = next == "24h" ? "Past 24 Hours" : (next == "1h" ? "Past Hour" : "Now")
                            Task { await model.switchWindow(win) }
                        }
                    )) {
                        Text("Now").tag("now")
                        Text("1 Hour").tag("1h")
                        Text("24 Hours").tag("24h")
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 8) {
                    Text("Grouping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Picker("Grouping", selection: Binding(
                        get: { snapshot.grouping.lowercased() == "processes" ? "processes" : "apps" },
                        set: { next in
                            let grp = next == "processes" ? "Processes" : "Apps"
                            Task { await model.switchGrouping(grp) }
                        }
                    )) {
                        Text("Apps").tag("apps")
                        Text("Processes").tag("processes")
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 8) {
                    Text("CPU Scale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Picker("CPU Scale", selection: Binding(
                        get: { isMachineScale ? "machine" : "core" },
                        set: { next in
                            let scale = next == "machine" ? "Share of Machine" : "Per Core"
                            Task { await model.switchCpuScale(scale) }
                        }
                    )) {
                        Text("Per Core").tag("core")
                        Text("Per Machine").tag("machine")
                    }
                    .pickerStyle(.segmented)
                }
                Text(scaleExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .disabled(!canEdit)
            if !canEdit {
                Text(Self.editOffNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if sortedRows.isEmpty {
                Text(snapshot.hasBaseline ? "Nothing is busy right now." : "Measuring…")
                    .foregroundStyle(.secondary)
            } else {
                // Quit and Tame exist only when the Mac owner turned them on.
                // Without this the swipe and long-press actions showed on
                // every row and answered 403 when used.
                let controlsOn = snapshot.remoteQuitAllowed == true
                ForEach(Array(sortedRows.enumerated()), id: \.element.id) { index, row in
                    let rank = index + 1
                    HStack(spacing: 10) {
                        Text("#\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(rank <= 3 ? Color.orange : Color.secondary)
                            .frame(width: 26, alignment: .leading)

                        Image(systemName: row.isApp ? "app.fill" : "cpu")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if model.samplingRowId == row.id {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel("Sampling")
                                }
                                if row.isSleepBlocker == true {
                                    Image(systemName: "moon.fill")
                                        .font(.caption)
                                        .foregroundStyle(.indigo)
                                        .accessibilityLabel("Preventing Sleep")
                                }
                                if row.isTamed == true {
                                    Text("TAMED")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange))
                                }
                            }
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.cpuText)
                                .font(.body.weight(sortOrder == .cpu ? .bold : .semibold).monospacedDigit())
                                .foregroundStyle(rowColor(row.severity))
                            Text(row.memoryText)
                                .font(.caption.weight(sortOrder == .memory ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(sortOrder == .memory ? Color.primary : Color.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if controlsOn && row.canQuit && row.pid != nil {
                            Button(role: .destructive) {
                                confirmQuit(row: row, force: false)
                            } label: {
                                Label("Quit", systemImage: "xmark.circle")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if controlsOn, row.canTame != false, row.pid != nil {
                            if row.isTamed == true {
                                Button {
                                    confirmTame(row: row, action: "untame")
                                } label: {
                                    Label("Restore", systemImage: "hare")
                                }
                                .tint(.blue)
                            } else {
                                Button {
                                    confirmTame(row: row, action: "tame")
                                } label: {
                                    Label("Tame", systemImage: "tortoise")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    .contextMenu {
                        if !controlsOn {
                            Text("Quit and Tame are off for \(snapshot.hostName).")
                            Text("Turn them on in Hog Hunter Settings > iPhone.")
                        }
                        if controlsOn, row.canTame != false, row.pid != nil {
                            if row.isTamed == true {
                                Button {
                                    confirmTame(row: row, action: "untame")
                                } label: {
                                    Label("Restore Normal Priority", systemImage: "hare")
                                }
                            } else {
                                Button {
                                    confirmTame(row: row, action: "tame")
                                } label: {
                                    Label("Tame App (Lower Priority)", systemImage: "tortoise")
                                }
                            }
                        }

                        if controlsOn, row.pid != nil {
                            Button {
                                confirmSample(row)
                            } label: {
                                Label("Sample for 3 Seconds", systemImage: "waveform.path.ecg")
                            }
                            .disabled(model.samplingRowId != nil)
                        }

                        if controlsOn && row.canQuit && row.pid != nil {
                            Button {
                                confirmQuit(row: row, force: false)
                            } label: {
                                Label("Quit \(row.name)", systemImage: "xmark.circle")
                            }
                            Button(role: .destructive) {
                                confirmQuit(row: row, force: true)
                            } label: {
                                Label("Force Quit \(row.name)", systemImage: "bolt.horizontal.circle")
                            }
                        } else if controlsOn, let reason = row.quitBlockReason {
                            Text("Protected: \(reason)")
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(snapshot.grouping == "Processes" ? "Busy Processes" : "Busy Apps")
                Spacer()
                Picker("Sort", selection: $sortOrder) {
                    ForEach(CompanionSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                .onChange(of: sortOrder) {
                    sortAscending = false
                }

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel(sortAscending ? "Sort lowest first" : "Sort highest first")
            }
        }

        Section {
            if snapshot.remoteQuitAllowed == true {
                if snapshot.rows.contains(where: { $0.canQuit }) {
                    Text("Swipe left to quit an app, swipe right to tame runaway CPU, or long-press to quit, tame or sample it on \(snapshot.hostName).\u{00A0} You confirm each one.\u{00A0} System processes and tasks owned by other users are protected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if sortedRows.isEmpty {
                    Text("Remote control is enabled on \(snapshot.hostName).  Waiting for active process telemetry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Remote control is enabled on \(snapshot.hostName).  All visible processes are protected system tasks and cannot be quit or tamed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Quitting from iPhone is off.  Turn on Allow iPhone to Quit or Tame Apps & Processes in Hog Hunter Settings > iPhone on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var storageContent: some View {
        // Mac storage is intentionally FIRST.  Prior to 1.0.6 the iPhone-storage
        // section sat on top and several users assumed it WAS the Mac storage
        // (the phone is showing its own storage, not the Mac's).  Putting the
        // Mac disk usage and the per-app breakdown up top is the principle that
        // answers "why does the iPhone show CPU and memory for the Mac but no
        // disk?" without burying the answer under a section titled differently.
        Section("Mac Disk Usage") {
            if let storage = snapshot.storage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Macintosh HD", systemImage: "internaldrive")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.0f%% Used", storage.usedPercent))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(storage.usedPercent > 90 ? Color.red : (storage.usedPercent > 75 ? Color.orange : Color.primary))
                    }

                    ProgressView(value: min(max(storage.usedPercent / 100.0, 0), 1.0))
                        .tint(storage.usedPercent > 90 ? Color.red : (storage.usedPercent > 75 ? Color.orange : Color.accentColor))

                    HStack {
                        Text(storage.usedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(storage.freeText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Disk telemetry will update with next sample.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        if let apps = snapshot.storage?.topApps, !apps.isEmpty {
            Section {
                ForEach(apps) { app in
                    macAppStorageRow(app)
                }
                if let scanned = snapshot.storage?.topAppsScannedAt {
                    HStack {
                        Spacer()
                        Text("Scanned \(Self.relativeTimeFormatter.localizedString(for: scanned, relativeTo: Date())) on \(snapshot.hostName).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                HStack {
                    Text("Mac Storage by App")
                    if let top = snapshot.storage?.topApps, top.contains(where: { $0.isHiddenHeavy }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                    }
                    Spacer()
                }
            } footer: {
                Text("Top apps on \(snapshot.hostName), sorted by total on-disk size.  Bundle is the .app; Hidden is everything else (Library/Caches, Containers, Group Containers, Saved State, etc.).  Open the Storage pane on the Mac for the full list and cleanup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if snapshot.storage != nil {
            // Storage summary landed but the per-app walk has not yet returned;
            // show a single "Scanning" hint instead of nothing so the section
            // does not silently disappear on first render.
            Section("Mac Storage by App") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning installed apps on \(snapshot.hostName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("iPhone Storage") {
            if let phoneStorage = iPhoneStorage.summary() {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(phoneStorage.name, systemImage: "iphone")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.0f%% Used", phoneStorage.usedPercent))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(phoneStorage.usedPercent > 90 ? Color.red : (phoneStorage.usedPercent > 80 ? Color.orange : Color.primary))
                    }

                    ProgressView(value: min(max(phoneStorage.usedPercent / 100.0, 0), 1.0))
                        .tint(phoneStorage.usedPercent > 90 ? Color.red : (phoneStorage.usedPercent > 80 ? Color.orange : Color.accentColor))

                    HStack {
                        Text(phoneStorage.usedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(phoneStorage.freeText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Reading iPhone storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Disk & System Clutter") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Safe Mac Clean", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if model.isCleaning || snapshot.cleanProgress?.isCleaning == true {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("Remotely trigger a safe Standard Clean on \(snapshot.hostName). Cleans user caches, logs, developer junk, and empties trash with instant APFS snapshot rollback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let progress = snapshot.cleanProgress, progress.isCleaning || model.isCleaning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(progress.statusText.isEmpty ? "Cleaning in progress…" : progress.statusText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(Int(progress.progress * 100))%")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(Color.accentColor)
                        }

                        ProgressView(value: max(0.05, progress.progress), total: 1.0)
                            .tint(.accentColor)

                        if let item = progress.currentItem, !item.isEmpty, item != progress.statusText {
                            Text(item)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if progress.totalItems > 0 {
                            HStack {
                                Text("\(progress.itemsCleaned) of \(progress.totalItems) items cleaned")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if progress.bytesReclaimed > 0 {
                                    Text("Reclaimed \(progress.formattedBytesReclaimed)")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }

                if let progress = snapshot.cleanProgress, progress.phase == "completed" {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reclaimed \(progress.formattedBytesReclaimed) (\(progress.itemsCleaned) items)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                            if let snap = progress.snapshotName {
                                Text("APFS Snapshot: \(snap)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } else if let result = model.lastCleanResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Reclaimed \(result.formattedBytesReclaimed) (\(result.itemsRemoved) items) with APFS snapshot.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                }

                if let error = model.cleanError ?? snapshot.cleanProgress?.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    showCleanConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if let progress = snapshot.cleanProgress, progress.isCleaning {
                            Text("Cleaning Mac… (\(Int(progress.progress * 100))%)")
                                .font(.subheadline.weight(.semibold))
                        } else if model.isCleaning {
                            Text("Cleaning Mac…")
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text("Clean Mac Clutter (Safe)")
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isCleaning || snapshot.cleanProgress?.isCleaning == true || snapshot.remoteCleanAllowed != true)

                if snapshot.remoteCleanAllowed != true {
                    Text("Cleaning from iPhone is off.  Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings > iPhone on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            NavigationLink {
                CleanerView(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Review & Choose What To Clean", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                    Text("Scan, tick items, try Extreme Clean, and read the cleanup history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Robotic Vacuum") {
            NavigationLink {
                VacuumView(snapshot: snapshot, model: model)
            } label: {
                VacuumSummaryRow(snapshot: snapshot)
            }
        }

        if let storage = snapshot.storage {
            Section("Cleanable Categories") {
                if let breakdown = storage.categoryBreakdown, !breakdown.isEmpty {
                    ForEach(breakdown) { category in
                        HStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .font(.title3)
                                .frame(width: 24)
                                .foregroundStyle(category.isExcluded ? Color.secondary : Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(category.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(category.isExcluded ? .secondary : .primary)
                                    if category.isExtremeOnly {
                                        Text("EXTREME ONLY")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.purple)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(Color.purple.opacity(0.12))
                                            )
                                    }
                                }
                                Text(category.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !category.isExcluded },
                                set: { _ in
                                    Task { await model.toggleCategoryExclusion(id: category.id) }
                                }
                            ))
                            .labelsHidden()
                            .disabled(!canEdit)
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    let excludedCats = storage.excludedCategories ?? []
                    if !excludedCats.isEmpty {
                        Text("Excluded: \(excludedCats.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("All standard categories included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Custom Excluded Folders") {
                let paths = storage.excludedPaths ?? []
                if paths.isEmpty {
                    Text("No custom folders excluded. Tap below to protect specific folders from cleaning.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await model.removeExcludedPath(path) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canEdit)
                        }
                    }
                    .onDelete { indices in
                        for index in indices {
                            let path = paths[index]
                            Task { await model.removeExcludedPath(path) }
                        }
                    }
                    .deleteDisabled(!canEdit)
                }

                Button {
                    newPathInput = ""
                    showAddPathAlert = true
                } label: {
                    Label("Exclude Folder…", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(!canEdit)

                if !canEdit {
                    Text(Self.editOffNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Excluded categories and folders are safely preserved across both Standard and Extreme clean runs on \(snapshot.hostName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var networkContent: some View {
        if let bandwidth = snapshot.bandwidth {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    BandwidthCard(title: "Now", down: bandwidth.downText, up: bandwidth.upText, footnote: bandwidth.nowFootnote)
                    BandwidthCard(title: "24-Hour Peak", down: bandwidth.peakDownText, up: bandwidth.peakUpText, footnote: bandwidth.peakFootnote)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                Text(bandwidth.peakHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = bandwidth.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Bandwidth on \(snapshot.hostName)")
            }
        }

        Section("Active Network Connections") {
            if let networkRows = snapshot.network, !networkRows.isEmpty {
                ForEach(networkRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .font(.body.weight(.medium))
                            Text("PID \(row.pid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(row.establishedCount) active")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }

                        if !row.sampleRemoteHosts.isEmpty {
                            Text(row.sampleRemoteHosts.joined(separator: ", "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "network.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(snapshot.networkNote ?? "No high-bandwidth connections detected on \(snapshot.hostName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }

    private func rowColor(_ severity: String) -> Color {
        severity == "calm" ? Color.primary : CompanionColor.color(severity)
    }

    /// One row of the new "Mac Storage by App" section.  Mirrors the Mac
    /// pane's `StorageRowView` at a glance level: app name + total bytes on
    /// the top line, bundle vs hidden split on the bottom, and a red outline
    /// when the app owns way more outside the .app than inside it.
    @ViewBuilder
    private func macAppStorageRow(_ app: CompanionAppStorageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if app.isHiddenHeavy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                        .accessibilityLabel("Hidden bytes flag")
                }
                Text(app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(app.totalText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 6) {
                Text("Bundle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(app.bundleText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Hidden")
                    .font(.caption2)
                    .foregroundStyle(app.isHiddenHeavy ? Color.red : Color.secondary)
                Text(app.hiddenText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(app.isHiddenHeavy ? .red : .secondary)
                if app.anyApproximate {
                    Text("approx")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(app.isHiddenHeavy ? Color.red.opacity(0.06) : Color.clear)
                .padding(.vertical, 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), total \(app.totalText), bundle \(app.bundleText), hidden \(app.hiddenText)\(app.isHiddenHeavy ? ", flagged: hidden exceeds five times bundle and over two hundred megabytes" : "")")
    }

    static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct MeterCard: View {
    let title: String
    let value: Double
    let headline: String
    let caption: String
    let severity: String
    /// Recent readings, oldest first.  Drawn with the same sparkline the Mac
    /// menu bar uses once there are enough to draw.
    var history: [Double]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(CompanionColor.color(severity))
            if let history, history.count >= 2 {
                CpuSparklineView(samples: history, width: 120, height: 24)
                    .accessibilityLabel("Recent CPU")
                    .accessibilityValue("Latest \(Int(history.last ?? 0)) percent")
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(headline), \(caption)")
    }
}

/// One of the Network tab's two bandwidth cards.  The Mac sends the text,
/// so this prints it as received.
private struct BandwidthCard: View {
    let title: String
    let down: String
    let up: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            rateRow(symbol: "arrow.down", word: "Download", text: down)
            rateRow(symbol: "arrow.up", word: "Upload", text: up)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("Download \(down), Upload \(up).\u{00A0} \(footnote)")
    }

    private func rateRow(symbol: String, word: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(word)
            Text(text)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// What a Sample for 3 Seconds produced.  The report itself stays on the Mac.
struct SampleResultView: View {
    let response: CompanionSampleResponse
    let hostName: String
    @Environment(\.dismiss) private var dismiss

    private var succeeded: Bool { response.status == "ok" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        succeeded ? "Sample Saved" : "Could Not Sample",
                        systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(succeeded ? Color.green : Color.orange)
                    if let text = response.error ?? response.message {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if succeeded {
                    Section("Report on \(hostName)") {
                        if let name = response.fileName {
                            LabeledContent("File") {
                                Text(name)
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if let bytes = response.bytes {
                            LabeledContent("Size", value: iPhoneStorage.format(bytes: UInt64(max(0, bytes))))
                        }
                    }
                    if let summary = response.summary, !summary.isEmpty {
                        Section {
                            ForEach(Array(summary.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Busiest Call Sites")
                        } footer: {
                            Text("The first lines of the report's top-of-stack summary.\u{00A0} Open the file on the Mac for the full call graph.")
                        }
                    }
                }
            }
            .navigationTitle(response.name.isEmpty ? "Sample" : response.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let severity: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(severity == "calm" ? Color.secondary : CompanionColor.color(severity))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

struct RemoteConnectSheet: View {
    @Bindable var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tailscale Name, IP, or Domain", text: $model.remoteHostDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    LabeledContent("Port") {
                        TextField("\(CompanionModel.defaultPort)", text: $model.remotePortDraft)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Mac Address")
                } footer: {
                    Text("Use your Mac's Tailscale name (like my-mac.tailnet.ts.net) or its 100.x.y.z address.  Hog Hunter on the Mac listens on port \(CompanionModel.defaultPort).  Using a VPN, port forward, or your own domain instead?  Point it at that port.")
                }

                Section {
                    TextField("Leave Blank to Approve on Mac", text: $model.remoteTokenDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    TextField("Mac Name (Optional)", text: $model.remoteNameDraft)
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("Leave the code blank and your Mac will ask whether to allow this iPhone.  Or type the code from Hog Hunter Settings > iPhone.")
                }

                if model.isWaitingForApproval {
                    Section {
                        Label("Check your Mac and click Allow.", systemImage: "desktopcomputer")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let error = model.remoteConnectError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        model.startRemoteConnect()
                    } label: {
                        HStack {
                            Spacer()
                            if model.isConnectingRemote {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(model.isWaitingForApproval ? "Waiting for Mac…" : (model.isConnectingRemote ? "Connecting…" : "Connect to Mac"))
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(model.isConnectingRemote || model.remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Connect by Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelRemoteConnect()
                        dismiss()
                    }
                }
            }
            .onChange(of: model.isRemoteSheetPresented) { _, isPresented in
                if !isPresented {
                    dismiss()
                }
            }
            .onDisappear {
                // cancelRemoteConnect() must also run for a connect that was just
                // scheduled: isConnectingRemote is not set until the task body runs.
                model.cancelRemoteConnect()
            }
        }
    }
}

enum CompanionColor {
    static func color(_ severity: String) -> Color {
        switch severity {
        case "hot":
            return Color(red: 0.75, green: 0.18, blue: 0.16)
        case "elevated":
            return Color(red: 0.80, green: 0.52, blue: 0.10)
        default:
            return Color.accentColor
        }
    }
}
