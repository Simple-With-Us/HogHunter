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
                message: model.statusLine + "  Hog Hunter shares while the Mac app is open and Share With iPhone is on.",
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
                message: "Open Hog Hunter on your Mac, then turn on Share With iPhone in Settings.  Both devices need the same Wi-Fi, or connect via Tailscale.",
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

struct DashboardView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @State private var selectedTab: CompanionTab = ProcessInfo.processInfo.arguments.contains("-HogHunterStorage") ? .storage : (ProcessInfo.processInfo.arguments.contains("-HogHunterNetwork") ? .network : .activity)
    @State private var sortOrder: CompanionSort = .cpu
    @State private var showCleanConfirm = false
    @State private var pendingQuitRow: CompanionRow?
    @State private var isForceQuit = false
    @State private var showQuitConfirm = false
    @State private var lastQuitResult: CompanionQuitResponse?
    @State private var showQuitResultAlert = false
    @State private var pendingTameRow: CompanionRow?
    @State private var pendingTameAction = "tame"
    @State private var lastTameAction = "tame"
    @State private var showTameConfirm = false
    @State private var lastTameResult: CompanionTameResponse?
    @State private var showTameResultAlert = false
    @State private var showAddPathAlert = false
    @State private var newPathInput = ""

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

    private var sortedRows: [CompanionRow] {
        snapshot.rows.sorted { a, b in
            switch sortOrder {
            case .cpu:
                if a.sortCPU != b.sortCPU {
                    return a.sortCPU > b.sortCPU
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .memory:
                if a.sortMemory != b.sortMemory {
                    return a.sortMemory > b.sortMemory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
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

            Picker("Tab", selection: $selectedTab) {
                ForEach(CompanionTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

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
                if let row = pendingQuitRow, let pid = row.pid {
                    Task {
                        let res = await model.quitProcess(pid: pid, force: isForceQuit)
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
                if let row = pendingTameRow, let pid = row.pid {
                    let action = pendingTameAction
                    lastTameAction = action
                    Task {
                        let res = await model.tameProcess(pid: pid, action: action)
                        lastTameResult = res
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
            lastTameResult?.error != nil
                ? (lastTameAction == "untame" ? "Could Not Restore Priority" : "Could Not Tame App")
                : "Priority Updated",
            isPresented: $showTameResultAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = lastTameResult?.error {
                Text(error)
            } else if let message = lastTameResult?.message {
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
        .onChange(of: model.showCleanDialogRequested) { _, requested in
            if requested {
                showCleanConfirm = true
                model.showCleanDialogRequested = false
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
                    severity: snapshot.pulse.cpuSeverity
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
            }
            .padding(.vertical, 2)
        }

        Section {
            if sortedRows.isEmpty {
                Text(snapshot.hasBaseline ? "Nothing is busy right now." : "Measuring…")
                    .foregroundStyle(.secondary)
            } else {
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
                        if row.canQuit && row.pid != nil {
                            Button(role: .destructive) {
                                confirmQuit(row: row, force: false)
                            } label: {
                                Label("Quit", systemImage: "xmark.circle")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if row.canTame != false, row.pid != nil {
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
                        if row.canTame != false, row.pid != nil {
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

                        if row.canQuit && row.pid != nil {
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
                        } else if let reason = row.quitBlockReason {
                            Text("Protected: \(reason)")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(snapshot.grouping == "Processes" ? "Busy Processes" : "Busy Apps")
                Spacer()
                Picker("Sort", selection: $sortOrder) {
                    ForEach(CompanionSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }
        }

        Section {
            if snapshot.remoteQuitAllowed != false, snapshot.rows.contains(where: { $0.canQuit }) {
                Text("Swipe left to quit an app, swipe right to tame runaway CPU, or long-press for options on \(snapshot.hostName).  You confirm each one.  System processes and tasks owned by other users are protected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Quitting from iPhone is off.  Turn on Allow iPhone to Quit or Tame Apps & Processes in Hog Hunter Settings > iPhone on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var storageContent: some View {
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

        Section("Disk & System Clutter") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Safe Mac Clean", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if model.isCleaning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("Remotely trigger a safe Standard Clean on \(snapshot.hostName). Cleans user caches, logs, developer junk, and empties trash with instant APFS snapshot rollback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let result = model.lastCleanResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Reclaimed \(result.formattedBytesReclaimed) (\(result.itemsRemoved) items) with APFS snapshot.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                }

                if let error = model.cleanError {
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
                        Text(model.isCleaning ? "Cleaning Mac…" : "Clean Mac Clutter (Safe)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isCleaning || snapshot.remoteCleanAllowed != true)

                if snapshot.remoteCleanAllowed != true {
                    Text("Cleaning from iPhone is off.  Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings > iPhone on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
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
                        }
                    }
                    .onDelete { indices in
                        for index in indices {
                            let path = paths[index]
                            Task { await model.removeExcludedPath(path) }
                        }
                    }
                }

                Button {
                    newPathInput = ""
                    showAddPathAlert = true
                } label: {
                    Label("Exclude Folder…", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
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
                    Text("No high-bandwidth connections detected on \(snapshot.hostName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }

    private func rowColor(_ severity: String) -> Color {
        severity == "calm" ? Color.primary : CompanionColor.color(severity)
    }
}

private struct MeterCard: View {
    let title: String
    let value: Double
    let headline: String
    let caption: String
    let severity: String

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
