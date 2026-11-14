import Darwin
import SwiftUI

extension HogRow {
    /// The actions the menu may offer for this row, computed locally the way
    /// the server computes them for its own processes.  Quit and Force Quit
    /// follow `canQuit`; Tame and Restore Priority follow `canTame`, and only
    /// the one that changes something is offered — Tame for a running hog,
    /// Restore Priority for a tamed one.  Sample follows `canSample`.
    var allowedActions: [String] {
        var actions: [String] = []
        if canQuit { actions += ["quit", "force-quit"] }
        if canTame { actions.append(isTamed ? "untame" : "tame") }
        if canSample { actions.append("sample") }
        return actions
    }

    /// Why the destructive actions are unavailable, in the server's terms:
    /// the row's quit block reason ("system process", "owned by another
    /// user", "this app"), or nil when nothing is blocked.
    var protectionReason: String? { quitBlockReason }

    func can(action: String) -> Bool {
        allowedActions.contains(action)
    }

    /// Sampling reads a process instead of stopping it, so the quit denylist
    /// does not apply: Finder, the Dock, and other protected names may still
    /// be sampled.  Hog Hunter itself, PID 1 and below (launchd and
    /// kernel_task), and history rows with no live pid are out.  Ownership
    /// cannot be read from a row, so it is rechecked by
    /// `ProcessControl.sampleChoice` at the moment Sample is chosen.
    var canSample: Bool {
        guard let pid else { return false }
        return pid > 1 && pid != getpid()
    }
}

/// The Mac counterpart of ServerProcessActions: the same five actions for a
/// process on this machine, gated locally instead of by the server.  Every
/// action re-checks the process identity at the moment it runs (see
/// ProcessControl), so a pid recycled since the last sample is never
/// signalled, reniced, or sampled by mistake.
struct MacProcessActions: View {
    let row: HogRow
    /// Used to run the actions and to report a failed sample; the row does
    /// not observe it, so a store update never redraws the list.
    let store: HogStore
    var showsStopButton = false
    var didAct: () -> Void = {}
    @State private var pending: PendingAction?
    @State private var sampleText: String?
    @State private var sampleFileName: String?
    @State private var isSampling = false

    private enum Action: String, Identifiable {
        case quit, forceQuit, tame, untame
        var id: String { rawValue }
        var title: String {
            switch self {
            case .quit: return "Quit"
            case .forceQuit: return "Force Quit"
            case .tame: return "Tame"
            case .untame: return "Restore Priority"
            }
        }
    }

    private struct PendingAction {
        let action: Action
        let row: HogRow
    }

    var body: some View {
        HStack(spacing: 3) {
            if showsStopButton {
                Button("Stop…") { pending = PendingAction(action: .quit, row: row) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!row.can(action: "quit"))
                    .help(row.protectionReason ?? "Ask this Mac process to quit after confirmation")
                    .accessibilityLabel("Stop \(row.name) on Mac")
            }
            actionMenu
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("Quit…") { pending = PendingAction(action: .quit, row: row) }.disabled(!row.can(action: "quit"))
            Button("Force Quit…", role: .destructive) { pending = PendingAction(action: .forceQuit, row: row) }
                .disabled(!row.can(action: "force-quit"))
            Divider()
            Button("Tame…") { pending = PendingAction(action: .tame, row: row) }.disabled(!row.can(action: "tame"))
            Button("Restore Priority…") { pending = PendingAction(action: .untame, row: row) }.disabled(!row.can(action: "untame"))
            Button("Sample For 3 Seconds") { sample() }
                .disabled(!row.can(action: "sample") || isSampling)
        } label: {
            Label("Process Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(row.allowedActions.isEmpty)
        .help(row.protectionReason ?? "Actions for \(row.name) on this Mac")
        .confirmationDialog(
            "\(pending?.action.title ?? "Change") \(pending?.row.name ?? row.name) On Mac?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmed = pending {
                let action = confirmed.action
                Button(action.title, role: action == .quit || action == .forceQuit ? .destructive : nil) {
                    pending = nil
                    let row = confirmed.row
                    switch action {
                    case .quit: store.quit(row, force: false)
                    case .forceQuit: store.quit(row, force: true)
                    case .tame: store.tame(row)
                    case .untame: store.untame(row)
                    }
                    didAct()
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if pending?.action == .tame || pending?.action == .untame {
                Text("This changes scheduling priority and may affect response times.\u{00A0} Hog Hunter rechecks the process identity and its protections before acting.")
            } else {
                Text("Unsaved work may be lost.\u{00A0} Hog Hunter rechecks the process identity and its protections before acting.")
            }
        }
        .sheet(isPresented: Binding(get: { sampleText != nil }, set: { if !$0 { sampleText = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mac Process Sample").font(.headline)
                Text("A three-second sample of \(row.name).\u{00A0} The full report is saved in Logs/HogHunter\(sampleFileName.map { " as \($0)" } ?? "").")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(sampleText ?? "").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { sampleText = nil }.keyboardShortcut(.defaultAction) }
            }.padding().frame(minWidth: 560, minHeight: 380)
        }
    }

    /// Samples the first live member that is still the process the row was
    /// sampled from.  A member that changed or may not be sampled is reported
    /// through the store's error line, the same channel the other actions
    /// use, and nothing is sampled.
    private func sample() {
        switch ProcessControl.sampleChoice(members: row.keys, fallbackName: row.name) {
        case .ready(let key, let name):
            store.lastError = nil
            isSampling = true
            SampleReport.run(name: name, pid: key.pid) { outcome in
                isSampling = false
                switch outcome {
                case .written(let url):
                    sampleFileName = url.lastPathComponent
                    let tail = SampleReport.tailText(of: url)
                    sampleText = tail.isEmpty
                        ? "The report was written but could not be read back.\u{00A0} Open it from Logs/HogHunter."
                        : tail
                case .failed(let message):
                    store.lastError = message
                }
            }
        case .blocked(let name, let reason):
            store.lastError = "\(name) is \(reason).\u{00A0} Hog Hunter will not sample it."
        case .changed(let name):
            store.lastError = "Nothing was sampled: \(name) changed since sampling."
        }
    }
}
