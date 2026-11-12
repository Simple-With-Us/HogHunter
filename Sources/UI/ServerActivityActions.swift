import SwiftUI

/// All mutations require an explicit choice and a current identity supplied by the server.
struct ServerProcessActions: View {
    let process: VPSProcess
    let host: String
    @ObservedObject var control: ServerControl
    var showsStopButton = false
    var didAct: () -> Void = {}
    @State private var pending: PendingAction?
    @State private var sampleText: String?

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
        let process: VPSProcess
    }

    var body: some View {
        HStack(spacing: 3) {
            if showsStopButton {
                Button("Stop…") { pending = PendingAction(action: .quit, process: process) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(control.isWorking || !process.can(action: "quit"))
                    .help(process.protectionReason ?? "Ask this server process to quit after confirmation")
                    .accessibilityLabel("Stop \(process.name) on server")
            }
            actionMenu
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("Quit…") { pending = PendingAction(action: .quit, process: process) }.disabled(!process.can(action: "quit"))
            Button("Force Quit…", role: .destructive) { pending = PendingAction(action: .forceQuit, process: process) }
                .disabled(!process.can(action: "force-quit"))
            Divider()
            Button("Tame…") { pending = PendingAction(action: .tame, process: process) }.disabled(!process.can(action: "tame"))
            Button("Restore Priority…") { pending = PendingAction(action: .untame, process: process) }.disabled(!process.can(action: "untame"))
            Button("Sample For 3 Seconds") {
                Task {
                    await control.sample(process: process, host: host)
                    sampleText = control.lastSampleText
                }
            }.disabled(!process.can(action: "sample"))
        } label: {
            Label("Process Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(control.isWorking || process.allowedActions?.isEmpty != false)
        .help(process.protectionReason ?? "Actions for \(process.name) on the server")
        .confirmationDialog(
            "\(pending?.action.title ?? "Change") \(pending?.process.name ?? process.name) On Server?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmed = pending {
                let action = confirmed.action
                Button(action.title, role: action == .quit || action == .forceQuit ? .destructive : nil) {
                    pending = nil
                    Task {
                        let process = confirmed.process
                        let interruptsWorkload = !(process.container ?? "").isEmpty
                        switch action {
                        case .quit, .forceQuit:
                            await control.stop(process: process, host: host, force: action == .forceQuit,
                                               allowWorkloadInterruption: interruptsWorkload)
                        case .tame:
                            await control.tame(process: process, host: host, allowWorkloadInterruption: interruptsWorkload)
                        case .untame:
                            await control.untame(process: process, host: host, allowWorkloadInterruption: interruptsWorkload)
                        }
                        didAct()
                    }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if pending?.action == .tame || pending?.action == .untame {
                Text("This changes scheduling priority and may affect response times.\u{00A0} The server rechecks the process identity and its protections before acting.")
            } else if !(pending?.process.container ?? "").isEmpty {
                Text("This interrupts a server workload and may lose unsaved work.\u{00A0} The server rechecks the process identity and its protections before acting.")
            } else {
                Text("Unsaved work may be lost.\u{00A0} The server rechecks the process identity and its protections before acting.")
            }
        }
        .sheet(isPresented: Binding(get: { sampleText != nil }, set: { if !$0 { sampleText = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Server Process Sample").font(.headline)
                Text("A three-second kernel-counter reading; no command arguments or environment values are collected.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(sampleText ?? "").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { sampleText = nil }.keyboardShortcut(.defaultAction) }
            }.padding().frame(minWidth: 560, minHeight: 380)
        }
    }
}

struct ServerWorkloadActions: View {
    let resource: VPSCoolifyResource
    let host: String
    @ObservedObject var control: ServerControl
    var didAct: () -> Void = {}
    @State private var pending: PendingAction?

    private struct PendingAction {
        let title: String
        let resource: VPSCoolifyResource
    }

    var body: some View {
        Menu {
            Button("Stop…", role: .destructive) { pending = PendingAction(title: "Stop", resource: resource) }.disabled(!resource.can(action: "stop"))
            Button("Restart…") { pending = PendingAction(title: "Restart", resource: resource) }.disabled(!resource.can(action: "restart"))
        } label: {
            Label("Workload Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(control.isWorking || resource.allowedActions?.isEmpty != false)
        .help(resource.protectionReason ?? "Actions for \(resource.name) on the server")
        .confirmationDialog(
            "\(pending?.title ?? "Change") \(pending?.resource.name ?? resource.name) On Server?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmed = pending {
                Button(confirmed.title, role: .destructive) {
                    pending = nil
                    Task {
                        let resource = confirmed.resource
                        if confirmed.title == "Restart" {
                            await control.restart(resource: resource, host: host, allowWorkloadInterruption: true)
                        } else if confirmed.title == "Stop" {
                            await control.stop(resource: resource, host: host, allowWorkloadInterruption: true)
                        }
                        didAct()
                    }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This interrupts the server workload and may lose unsaved work.\u{00A0} Coolify may restart workloads it is configured to keep alive; changed or protected containers are refused.")
        }
    }
}
