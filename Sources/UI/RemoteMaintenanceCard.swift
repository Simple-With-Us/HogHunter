import SwiftUI

/// Manual server control is independent of whether Mac maintenance includes it.
struct RemoteMaintenanceCard: View {
    @ObservedObject var maintain: MaintainStore
    @StateObject private var control: ServerMaintenanceControl
    @State private var selected = Set(ServerMaintenanceStrategy.defaults)
    @State private var pending: PendingMaintenanceRequest?
    @State private var requestError: String?

    @MainActor
    init(maintain: MaintainStore, control: ServerMaintenanceControl? = nil) {
        self.maintain = maintain
        _control = StateObject(wrappedValue: control ?? ServerMaintenanceControl())
    }

    private var host: String { maintain.coolifyHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { control.isWorking || maintain.isRunningNow }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Remote Server Maintenance").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if busy { ProgressView().controlSize(.small).accessibilityLabel("Running server maintenance") }
                }
                if host.isEmpty {
                    Text("No remote server is configured.\u{00A0} Set one in Settings, then scan or run it from here.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(host).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Toggle("Include in Mac Maintenance", isOn: Binding(
                        get: { maintain.isStepEnabled("coolify_remote") },
                        set: { maintain.setStepEnabled("coolify_remote", enabled: $0) }
                    ))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Uses this Mac’s maintenance schedule; the server’s own schedule is unchanged.")
                    if !maintain.stepTogglesPersisted { Text("Saving schedule preference…").foregroundStyle(.secondary) }
                    Text("Manual actions work with this option off.\u{00A0} The server’s own schedule is unchanged.")
                        .foregroundStyle(.secondary)
                    ForEach(ServerMaintenanceStrategy.allCases) { strategy in
                        Toggle(strategy.title, isOn: Binding(
                            get: { selected.contains(strategy) },
                            set: { if $0 { selected.insert(strategy) } else { selected.remove(strategy) } }
                        )).toggleStyle(.checkbox).disabled(busy)
                    }
                    Text("Only age-qualified, unused items are eligible.\u{00A0} Containers, volumes and active logs are protected.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Scan") { startScan() }
                        Button("Run Now") { pending = makeRequest(.run) }
                    }.disabled(busy || selected.isEmpty)
                }
                if let message = requestError ?? control.message {
                    Text(message).foregroundStyle(.secondary)
                }
                if let error = maintain.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if let result = control.result {
                    ForEach(result.strategies) { row in
                        let title = ServerMaintenanceStrategy(rawValue: row.id)?.title ?? "Selected Strategy"
                        let eligibilityKnown = row.eligibilityIsKnown(in: result.status)
                        if row.id == "package-cache" || row.id == "rotated-logs" {
                            let eligibility = eligibilityKnown ? "\(row.candidateCount) eligible files" : "eligibility not determined"
                            Text("\(title): \(eligibility); \(row.removedCount) files removed")
                        } else {
                            let eligibility = eligibilityKnown ? "\(row.candidateCount) eligible records" : "eligibility not determined"
                            Text("\(title): \(eligibility); \(row.attemptedCount) cleanup attempts")
                        }
                    }
                    Text("Removed file bytes (logical): \(HogFormat.memory(UInt64(result.removedFileBytes)))")
                    Text("Observed available-space change: \(signedBytes(result.observedFreeDeltaBytes))")
                    Text("Available space also changes with other server activity; Docker requests do not prove physical bytes reclaimed.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .sheet(item: $pending) { request in
            ServerMaintenanceConfirmation(request: request) { imageAcknowledged in
                pending = nil
                Task { await control.perform(request, confirmed: true, imageRemovalConfirmed: imageAcknowledged) }
            } cancel: { pending = nil }
        }
    }

    private func makeRequest(_ mode: PendingMaintenanceRequest.Mode) -> PendingMaintenanceRequest? {
        requestError = nil
        do { return try PendingMaintenanceRequest(host: host, mode: mode, strategies: Array(selected)) }
        catch { requestError = "Configure a valid SSH host and select at least one strategy."; return nil }
    }

    private func startScan() {
        guard let request = makeRequest(.scan) else { return }
        Task { await control.perform(request) }
    }

    private func signedBytes(_ bytes: Int64) -> String {
        let magnitude = bytes.magnitude
        return (bytes < 0 ? "−" : bytes > 0 ? "+" : "") + HogFormat.memory(magnitude)
    }
}

private struct ServerMaintenanceConfirmation: View {
    let request: PendingMaintenanceRequest
    let confirm: (Bool) -> Void
    let cancel: () -> Void
    @State private var acknowledgeImages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Server Maintenance?").font(.headline)
            Text(request.host).font(.system(.body, design: .monospaced))
            Text(request.strategies.map(\.title).joined(separator: ", "))
            Text("This permanently removes eligible selected items, even when disk pressure is low.\u{00A0} The server rechecks age, current use, protection markers and the cleanup lock.")
            if request.includesImages {
                Text("Removing old untagged images can remove local rollback options and require downloading or rebuilding them again.")
                Toggle("I Accept the Rollback and Download Consequences", isOn: $acknowledgeImages)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Run Selected Maintenance") { confirm(acknowledgeImages) }
                    .disabled(request.includesImages && !acknowledgeImages)
            }
        }.padding(20).frame(width: 440)
    }
}
