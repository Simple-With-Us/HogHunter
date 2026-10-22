import SwiftUI

/// The one action the server scope of the panel can take.
///
/// The server scope used to be display-only:  the owner could read the
/// server's CPU, memory and disks but could not act on them.  The remote
/// maintenance step is the step that belongs to the server, and it is the same
/// step the Mac's Maintenance tab runs, against the same configured host.
///
/// It stays off until the owner turns it on, and it asks before it runs,
/// because it prunes containers, images and logs on a machine the owner is not
/// sitting at.
struct RemoteMaintenanceCard: View {
    @ObservedObject var maintain: MaintainStore
    /// Set when the owner asks to run the maintenance, so the confirmation can
    /// name the host the run will reach.
    @State private var confirmRun = false

    private var host: String {
        maintain.coolifyHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEnabled: Bool {
        maintain.isStepEnabled("coolify_remote")
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Remote Server Maintenance")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if maintain.isRunningNow {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Running remote maintenance")
                    }
                }
                if host.isEmpty {
                    Text("No remote server is configured.\u{00A0} Set one in Settings, then run it from here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(host)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("The remote server this runs against.")
                    Toggle("Run on Schedule", isOn: Binding(
                        get: { isEnabled },
                        set: { maintain.setStepEnabled("coolify_remote", enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .controlSize(.small)
                    HStack(spacing: 8) {
                        Button("Run Now") { confirmRun = true }
                            .disabled(maintain.isRunningNow || !isEnabled || !maintain.stepTogglesPersisted)
                        if !maintain.stepTogglesPersisted {
                            Text("Saving…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else if !isEnabled {
                            Text("Turn on Run on Schedule or use Run Now.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let err = maintain.lastError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog(
            "Run remote maintenance on \(host)?",
            isPresented: $confirmRun,
            titleVisibility: .visible
        ) {
            Button("Run on \(host)") { maintain.runStep("coolify_remote") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This prunes unused containers, images and logs on \(host) over SSH.\u{00A0} It cannot be undone.")
        }
    }
}
