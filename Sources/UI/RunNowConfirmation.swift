import SwiftUI

/// Copy for the Run Now confirmations, kept as data so tests can pin the
/// wording without rendering a sheet.  Title Case chrome, NBSP body copy.
enum RunNowCopy {
    static let maintainTitle = "Run Maintenance Now?"
    static let maintainBody = "This runs a full maintenance pass now, including every enabled step.\u{00A0} Steps can remove files, retire merged worktrees and run on a configured remote server, and removed items cannot be recovered."
    static let maintainConfirm = "Run Maintenance"
    static let regimenTitle = "Run Automatic Cleanup Now?"
    static let regimenBody = "This runs the automatic cleanup now, ahead of its schedule.\u{00A0} It removes items matched by the enabled rules, and removed items cannot be recovered."
    static let regimenConfirm = "Run Cleanup"
}

/// Confirmation for a manual full Maintain run, in the shape
/// `RemoteMaintenanceCard` uses for server maintenance.
struct MaintainRunConfirmationView: View {
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RunNowCopy.maintainTitle).font(.headline)
            Text(RunNowCopy.maintainBody)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(RunNowCopy.maintainConfirm, action: confirm)
            }
        }.padding(20).frame(width: 440)
    }
}

/// Confirmation for a manual Automatic Cleanup run.
struct RegimenRunConfirmationView: View {
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RunNowCopy.regimenTitle).font(.headline)
            Text(RunNowCopy.regimenBody)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(RunNowCopy.regimenConfirm, action: confirm)
            }
        }.padding(20).frame(width: 440)
    }
}
