import AppKit
import SwiftUI

/// One hog: icon, name, detail, and the two numbers that matter, with a Quit
/// button when quitting is actually allowed and a context menu of the things
/// you reach for next.
struct HogRowView: View {
    let row: HogRow
    let scale: CpuScale
    let coreCount: Int
    /// Used only to report a failed action; the row does not observe it, so a
    /// store update never redraws twenty-five rows.
    let store: HogStore
    let onQuit: () -> Void

    /// History rows describe a key that may be long gone, so they offer none
    /// of the actions that need a live pid.
    private var isLive: Bool { !row.keys.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(HogFormat.cpu(row.cpuPercent, scale: scale, coreCount: coreCount))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(cpuColor)
                Text(HogFormat.memory(row.memoryBytes))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            trailingControl
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu { menu }
    }

    /// A hot row earns its color; a quiet one stays in the ordinary text color
    /// so the list does not glow blue from top to bottom.  The colour tracks
    /// the value the user is actually looking at, so a process showing 12.5%
    /// on the `machineShare` scale (one core on an 8-core machine) is calm,
    /// even though the same value on the per-core scale would be elevated.
    private var cpuColor: Color {
        let severity = Severity.forProcessCpu(row.cpuPercent, scale: scale, coreCount: coreCount)
        return severity == .calm ? Color.primary : severity.color
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if row.canQuit {
            Button("Quit", action: onQuit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quit This Process")
        } else if isLive, let reason = row.quitBlockReason {
            Image(systemName: "lock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help("Quit is unavailable: \(reason).")
                .accessibilityLabel("Quit is unavailable: \(reason)")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var menu: some View {
        if isLive {
            Button("Copy PID") { copyPids() }
            Button("Reveal in Finder") { reveal() }
                .disabled((row.path ?? "").isEmpty)
            Button("Sample for 3 Seconds") { sample() }
            Divider()
        }
        Button("Open Activity Monitor") { HogActions.openActivityMonitor() }
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
        guard let pid = row.pid else { return }
        store.lastError = nil
        SampleReport.run(name: row.name, pid: pid) { outcome in
            switch outcome {
            case .written(let url):
                NSWorkspace.shared.open(url)
            case .failed(let message):
                store.lastError = message
            }
        }
    }
}

/// Actions that are not specific to one row.
enum HogActions {
    static let activityMonitorURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"
    )

    static func openActivityMonitor() {
        NSWorkspace.shared.open(activityMonitorURL)
    }

    @MainActor
    static func openStorageWindow(openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "hoghunter.storage")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            bringWindowToFront(titles: ["Storage", "Disk Cleaner", "App Storage"], id: "hoghunter.storage")
        }
    }

    @MainActor
    static func openNetworkWindow(openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "hoghunter.network")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            bringWindowToFront(titles: ["Network"], id: "hoghunter.network")
        }
    }

    @MainActor
    static func bringWindowToFront(titles: [String], id: String) {
        // Dismiss any open MenuBarExtra panel so the standalone window is never obscured beneath it
        for window in NSApp.windows {
            if window is NSPanel || window.className.contains("MenuBarExtra") || window.styleMask.contains(.nonactivatingPanel) {
                window.orderOut(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            let matchesId = window.identifier?.rawValue.contains(id) == true
            let matchesTitle = titles.contains(window.title)
            if matchesId || matchesTitle {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

/// Runs `/usr/bin/sample` against one pid and writes the report where the user
/// can find it again.  Everything but the completion runs off the main thread.
enum SampleReport {
    enum Outcome {
        case written(URL)
        case failed(String)
    }

    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/HogHunter", isDirectory: true)

    /// Calls `completion` on the main queue with the written file or a
    /// one-line failure fit for the panel.
    static func run(
        name: String,
        pid: pid_t,
        seconds: Int = 3,
        completion: @escaping (Outcome) -> Void
    ) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName)-\(pid)-\(stamp.string(from: Date())).txt")

        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (Outcome) -> Void = { outcome in
                DispatchQueue.main.async { completion(outcome) }
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            } catch {
                finish(.failed("Could not create the log folder: \(error.localizedDescription)"))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), String(seconds), "-file", url.path]
            let errors = Pipe()
            // The report goes to the `-file` path, so stdout carries nothing
            // worth keeping.  /dev/null rather than an undrained pipe, which
            // would deadlock the moment `sample` did write something.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
            } catch {
                finish(.failed("Could not run sample: \(error.localizedDescription)"))
                return
            }
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let text = String(data: errorData, encoding: .utf8) ?? ""
                let firstLine = text
                    .split(separator: "\n")
                    .first
                    .map(String.init) ?? "sample exited with code \(process.terminationStatus)"
                finish(.failed("Could not sample \(name): \(firstLine)"))
                return
            }
            finish(.written(url))
        }
    }
}
