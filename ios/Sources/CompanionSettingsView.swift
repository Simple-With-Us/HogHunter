import SwiftUI

/// The Mac's refresh interval, alerts and webhook, edited from the phone.
///
/// Every control sends the change to the Mac, which checks it again and
/// applies it the way Settings does.  The screen shows what the Mac holds, so
/// a change the Mac refuses snaps back instead of staying on screen.  The
/// webhook URL is the one secret here: the Mac never sends it, so this screen
/// shows its host and can replace or remove it, never read it.
struct MacSettingsView: View {
    let snapshot: CompanionSnapshot
    @Bindable var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    @State private var thresholdDraft: Double = 300
    @State private var minutesDraft: Int = 5
    @State private var isEditingThreshold = false
    /// The stepper's debounced send.  Only the stepper's own setter schedules
    /// one, so putting the Mac's value back into the draft cannot send anything.
    @State private var pendingSend: Task<Void, Never>?
    @State private var sendGeneration = 0
    @State private var showWebhookEditor = false
    @State private var webhookDraft = ""
    @State private var webhookDraftError: String?
    @State private var showRemoveWebhookConfirm = false

    private var canEdit: Bool { snapshot.remoteEditAllowed == true }

    static let editOffNote = "Changing Mac settings from iPhone is off.\u{00A0} Turn on Allow iPhone to Change Exclusions & View in Hog Hunter Settings > iPhone on your Mac."

    var body: some View {
        NavigationStack {
            Form {
                if !canEdit {
                    Section {
                        Text(Self.editOffNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let settings = snapshot.settings {
                    refreshSection(settings)
                    alertsSection(settings)
                    webhookSection(settings)
                    Section {
                        Text("A change here is saved on \(snapshot.hostName) exactly as if you made it in Hog Hunter Settings.\u{00A0} The Mac checks every value before it applies it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("This Mac's copy of Hog Hunter is older than this app and does not share its settings.\u{00A0} Update it on the Mac.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Mac Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { syncDrafts() }
            .onChange(of: snapshot.settings) { _, _ in syncDrafts() }
            .alert(
                "The Mac Did Not Accept That",
                isPresented: Binding(
                    get: { model.settingsError != nil },
                    set: { if !$0 { model.settingsError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.settingsError = nil }
            } message: {
                Text(model.settingsError ?? "")
            }
            .alert("Remove the Webhook?", isPresented: $showRemoveWebhookConfirm) {
                Button("Remove Webhook", role: .destructive) {
                    Task { await model.updateSettings(CompanionSettingsUpdateRequest(webhookURL: "")) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(snapshot.hostName) will stop sending sustained-hog alerts to it.")
            }
            .sheet(isPresented: $showWebhookEditor) {
                webhookEditor
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Sections

    private func refreshSection(_ settings: CompanionSettingsSummary) -> some View {
        Section {
            Picker("Refresh Every", selection: Binding(
                get: { settings.refreshInterval },
                set: { next in Task { await model.updateSettings(CompanionSettingsUpdateRequest(refreshInterval: next)) } }
            )) {
                ForEach(refreshChoices(including: settings.refreshInterval), id: \.self) { seconds in
                    Text("\(Int(seconds)) Seconds").tag(seconds)
                }
            }
            .disabled(!canEdit || model.isApplyingSettings)
        } header: {
            Text("Sampling")
        } footer: {
            Text("How often \(snapshot.hostName) samples processes.\u{00A0} A shorter interval is more current and uses a little more CPU.")
        }
    }

    private func alertsSection(_ settings: CompanionSettingsSummary) -> some View {
        Section {
            Toggle("Notify Me About Sustained Hogs", isOn: Binding(
                get: { settings.alertsEnabled },
                set: { next in Task { await model.updateSettings(CompanionSettingsUpdateRequest(alertsEnabled: next)) } }
            ))
            .disabled(!canEdit || model.isApplyingSettings)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CPU Above")
                    Spacer()
                    Text("\(Int(thresholdDraft))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $thresholdDraft,
                    in: CompanionSettingsLimits.alertThresholdRange,
                    step: CompanionSettingsLimits.alertThresholdStep
                ) { editing in
                    isEditingThreshold = editing
                    if !editing { sendThreshold() }
                }
                Text(thresholdExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!canEdit || !settings.alertsEnabled)

            Stepper(
                value: Binding(
                    get: { minutesDraft },
                    set: { next in
                        minutesDraft = next
                        schedule(CompanionSettingsUpdateRequest(alertSustainedMinutes: next))
                    }
                ),
                in: CompanionSettingsLimits.alertSustainedMinutesRange
            ) {
                Text("For \(minutesDraft) \(minutesDraft == 1 ? "minute" : "minutes")")
            }
            .disabled(!canEdit || !settings.alertsEnabled || model.isApplyingSettings)

            if settings.alertsEnabled, settings.notificationsDenied == true {
                Text("Notifications are off for Hog Hunter in System Settings on \(snapshot.hostName).")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if settings.alertsEnabled {
                Text("If macOS asks \(snapshot.hostName) for permission to notify, answer it on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Alerts")
        }
    }

    private func webhookSection(_ settings: CompanionSettingsSummary) -> some View {
        Section {
            LabeledContent("Webhook") {
                Text(settings.webhookConfigured ? (settings.webhookHost ?? "Set") : "Not Set")
                    .foregroundStyle(settings.webhookConfigured ? Color.primary : Color.secondary)
            }
            if let status = settings.webhookStatus, settings.webhookConfigured {
                LabeledContent("Last Delivery") {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(status.hasPrefix("Delivered") ? Color.secondary : Color.red)
                        .multilineTextAlignment(.trailing)
                }
            }
            Button(settings.webhookConfigured ? "Replace Webhook" : "Add Webhook") {
                webhookDraft = ""
                webhookDraftError = nil
                showWebhookEditor = true
            }
            .disabled(!canEdit || model.isApplyingSettings)
            Button("Send Test Webhook") {
                Task { await model.updateSettings(CompanionSettingsUpdateRequest(testWebhook: true)) }
            }
            .disabled(!canEdit || !settings.webhookConfigured || model.isApplyingSettings)
            if settings.webhookConfigured {
                Button("Remove Webhook", role: .destructive) {
                    showRemoveWebhookConfirm = true
                }
                .disabled(!canEdit || model.isApplyingSettings)
            }
            if let notice = model.settingsNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Webhook & Pushover")
        } footer: {
            Text("The webhook address is a secret.\u{00A0} \(snapshot.hostName) never sends it to this iPhone, so it shows only the host.\u{00A0} It must start with https, and it crosses your network without encryption on the way to the Mac, so set it on your home network or over Tailscale.")
        }
    }

    private var webhookEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://", text: $webhookDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    if let error = webhookDraftError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Webhook Address")
                } footer: {
                    Text("Slack, Discord, Pushover or your own endpoint.\u{00A0} \(snapshot.hostName) posts a JSON alert to it when a sustained hog triggers.")
                }
            }
            .navigationTitle(snapshot.settings?.webhookConfigured == true ? "Replace Webhook" : "Add Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showWebhookEditor = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveWebhook() }
                        .disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func saveWebhook() {
        let trimmed = webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              trimmed.count <= CompanionSettingsLimits.webhookMaxLength else {
            webhookDraftError = "Enter an https address, like https://hooks.example.com/alerts."
            return
        }
        showWebhookEditor = false
        Task { await model.updateSettings(CompanionSettingsUpdateRequest(webhookURL: trimmed)) }
    }

    private func sendThreshold() {
        guard let settings = snapshot.settings, thresholdDraft != settings.alertThresholdPercent else { return }
        Task { await model.updateSettings(CompanionSettingsUpdateRequest(alertThresholdPercent: thresholdDraft)) }
    }

    /// A stepper held down fires once per tap.  Waiting a moment sends the
    /// last value instead of one request per tap.
    private func schedule(_ update: CompanionSettingsUpdateRequest) {
        pendingSend?.cancel()
        sendGeneration += 1
        let mine = sendGeneration
        pendingSend = Task {
            try? await Task.sleep(for: .milliseconds(600))
            // A newer tap owns the stepper now: only the last value is sent.
            guard !Task.isCancelled, sendGeneration == mine else { return }
            await model.updateSettings(update)
            guard sendGeneration == mine else { return }
            pendingSend = nil
            // A change the Mac took reaches the draft through the snapshot's own
            // change.  One it refused leaves the snapshot as it was, so show
            // what the Mac holds.
            if model.settingsError != nil { syncDrafts() }
        }
    }

    /// Brings the drafts back to what the Mac holds, unless a finger is on the slider.
    private func syncDrafts() {
        guard let settings = model.snapshot?.settings ?? snapshot.settings else { return }
        if !isEditingThreshold { thresholdDraft = settings.alertThresholdPercent }
        if pendingSend == nil { minutesDraft = settings.alertSustainedMinutes }
    }

    /// The Mac's own choices, plus the current value when something else set it.
    private func refreshChoices(including current: Double) -> [Double] {
        var choices = CompanionSettingsLimits.refreshIntervals
        if !choices.contains(current) { choices.append(current); choices.sort() }
        return choices
    }

    /// The threshold is stated on the per-core scale whatever the rows show,
    /// because that is the number the alert compares against.
    private var thresholdExplanation: String {
        let cores = thresholdDraft / 100
        let coreText = cores == cores.rounded() ? String(format: "%.0f", cores) : String(format: "%.1f", cores)
        return "\(Int(thresholdDraft))% of one core, about \(coreText) \(cores == 1 ? "core" : "cores") fully busy."
    }
}
