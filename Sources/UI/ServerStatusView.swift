import AppKit
import SwiftUI

/// The remote server's headline, on the main window.
///
/// Owner 2026-10-19: the server readings used to live inside the Maintain
/// tab, where the card buried the maintenance content the tab exists for and
/// the readings themselves sat below the fold, so nobody knew they were
/// there.  The strip puts the answer on the Activity tab, where it is always
/// on screen, and the Server tab holds the full card.
///
/// The strip is one line: the host, then CPU, memory and disk, each coloured
/// by its own severity so a reader sees *which* number is the problem.  It
/// appears only when a host is configured: with no server there is nothing to
/// say, and the Server tab explains how to set one up.
struct VPSStatusStripView: View {
    @ObservedObject var store: VPSStatusStore
    /// Opens the Server tab.
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)

                if let snapshot = store.snapshot {
                    Text(snapshot.host)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    headline(snapshot)
                } else if store.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Reading the server…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let error = store.errorMessage, !error.isEmpty {
                    Text("Server unreadable")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .help(error)
                } else {
                    Text("Reading the server…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if let snapshot = store.snapshot {
                    Text(snapshot.relativeTimeString())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Remote server status.  Click for the full report.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the server tab")
    }

    /// What a screen reader says.  The numbers are in the label, not only in
    /// the drawing: the whole point of the strip is that the server's state is
    /// readable without looking closely at a row of percentages.
    private var accessibilityLabel: String {
        Self.stripLabel(snapshot: store.snapshot)
    }

    /// The strip's spoken label, from the snapshot alone, so it can be pinned
    /// by a test: the host, then each reading.
    static func stripLabel(snapshot: VPSStatusSnapshot?) -> String {
        guard let snapshot, let headline = snapshot.headline else {
            return "Remote server status"
        }
        var parts = ["Server \(headline.host)"]
        if let cpu = headline.cpuText { parts.append("CPU \(cpu)") }
        if let memory = headline.memoryText { parts.append("RAM \(memory)") }
        if let disk = headline.diskText { parts.append("disk \(disk)") }
        return parts.joined(separator: ", ")
    }

    /// CPU, memory and disk, each with its own severity colour.
    @ViewBuilder
    private func headline(_ snapshot: VPSStatusSnapshot) -> some View {
        if let headline = snapshot.headline {
            HStack(spacing: 10) {
                metric("CPU", headline.cpuText, headline.cpuSeverity)
                metric("RAM", headline.memoryText, headline.memorySeverity)
                metric("Disk", headline.diskText, headline.diskSeverity)
            }
        }
    }

    private func metric(_ label: String, _ value: String?, _ severity: Severity?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(severity?.color ?? .secondary)
        }
    }
}

/// The Server tab: the full card, with a line saying what it is.
///
/// The remote host is a peer machine, not a part of the maintenance: owner
/// 2026-10-19, "the server is just another computer/operational platform like
/// another mac would be".  So its readings live here, in their own tab, and
/// the Maintain tab carries no server figures at all.
struct ServerStatusView: View {
    @ObservedObject var store: VPSStatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Server")
                    .font(.system(size: 13, weight: .semibold))
            }

            VPSResourceCardView(store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
