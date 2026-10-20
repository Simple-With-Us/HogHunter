#if os(macOS)
import SwiftUI

@MainActor
struct MountedDriveUsageView: View {
    @StateObject private var store: MountedDriveStore
    private let isActive: Bool

    init(store: MountedDriveStore? = nil, isActive: Bool = true) {
        _store = StateObject(wrappedValue: store ?? MountedDriveStore())
        self.isActive = isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.rows) { drive in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(drive.name, systemImage: "externaldrive")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(drive.usedPercent.map { String(format: "%.0f%% used", $0) } ?? "unavailable")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(color(drive.severity))
                    }
                    if let percent = drive.usedPercent {
                        ProgressView(value: percent, total: 100)
                            .tint(color(drive.severity))
                    }
                    if let free = drive.availableBytes, let total = drive.totalBytes {
                        Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .help(drive.path)
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { break }
            }
        }
    }

    private func color(_ severity: MountedDriveUsage.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unavailable: return .secondary
        }
    }
}
#endif
