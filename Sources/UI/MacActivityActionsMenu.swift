import AppKit
import SwiftUI

/// Quick-panel Mac process actions: the same things the dashboard row's
/// context menu offers, shown inline so the panel's Mac column reaches as far
/// as the server column.  Quit stays on the existing Stop button, which
/// confirms first; these are the non-destructive companions - priority,
/// sampling, Finder and the clipboard.
struct MacActivityActionsMenu: View {
    let row: HogRow
    /// Used only to run and report the actions; the menu does not observe the
    /// store, so a store update never redraws the rows around it.
    let store: HogStore

    var body: some View {
        Menu {
            if row.canTame {
                if row.isTamed {
                    Button("Restore Priority (Untame)") { store.untame(row) }
                } else {
                    Button("Tame Hog (Background QoS)") { store.tame(row) }
                }
                Divider()
            }
            Button("Sample for 3 Seconds") { sample() }
                .disabled(row.pid == nil)
            Button("Reveal in Finder") { reveal() }
                .disabled((row.path ?? "").isEmpty)
            Button("Copy PID") { copyPids() }
        } label: {
            Label("Process Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Actions for \(row.name) on this Mac")
        .accessibilityLabel("Actions for \(row.name) on Mac")
    }

    private func copyPids() {
        let pids = row.keys.map { String($0.pid) }.joined(separator: ", ")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pids, forType: .string)
    }

    private func reveal() {
        guard let path = row.path, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func sample() {
        store.lastError = nil
        store.lastNotice = nil
        // Same live identity and ownership gate the phone-triggered sample
        // uses: a pid that now belongs to something else, Hog Hunter itself,
        // a system process or another user's process is never sampled.
        switch ProcessControl.sampleChoice(members: row.keys, fallbackName: row.name) {
        case .ready(let key, let name):
            SampleReport.run(name: name, pid: key.pid) { outcome in
                switch outcome {
                case .written(let url):
                    NSWorkspace.shared.open(url)
                case .failed(let message):
                    store.lastError = message
                }
            }
        case .blocked(let name, let reason):
            store.lastError = "\(name) is \(reason).\u{00A0} Hog Hunter will not sample it."
        case .changed(let name):
            store.lastError = "\(name) changed since sampling.\u{00A0} Hog Hunter left it alone."
        }
    }
}
