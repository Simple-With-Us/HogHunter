#if os(macOS)
import Foundation
import Combine

struct DirectoryUsageRow: Identifiable, Equatable {
    var id: String { path }
    let title: String
    let path: String
    var bytes: Int64?
    var sampledAt: Date?
    var percentChange: Double?
    var isUnavailable = false
}

@MainActor
final class DirectoryUsageStore: ObservableObject {
    typealias Probe = @Sendable (String) -> Int64?
    @Published private(set) var rows: [DirectoryUsageRow]
    @Published private(set) var isRefreshing = false
    private let history: SizeGrowthHistory
    private let probe: Probe
    private let now: () -> Date
    private let host: String
    private var lastAttempt: Date?

    init(history: SizeGrowthHistory = .shared,
         candidates: [(title: String, path: String)]? = nil,
         host: String = "mac-local", now: @escaping () -> Date = Date.init,
         probe: @escaping Probe = { DirectoryUsageStore.measure($0) }) {
        self.history = history
        self.probe = probe
        self.now = now
        self.host = host
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = [("Code", "\(home)/Code"), ("Coding Lanes", "\(home)/apps/lanes"),
                        ("Codex", "\(home)/.codex"), ("Claude", "\(home)/.claude"),
                        ("MiniMax", "\(home)/.minimax"), ("MiniMax Code", "\(home)/.minimax-code"),
                        ("npm Cache", "\(home)/.npm"), ("Derived Data", "\(home)/Library/Developer/Xcode/DerivedData"),
                        ("Caches", "\(home)/.cache"), ("Temporary Files", "/private/tmp")]
        var accepted: [String] = []
        rows = (candidates ?? defaults).compactMap { title, path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard !accepted.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") || $0.hasPrefix(resolved + "/") }) else { return nil }
            accepted.append(resolved)
            let sample = history.latest(host: host, metric: "directory", path: resolved)
            return DirectoryUsageRow(title: title, path: resolved, bytes: sample?.bytes, sampledAt: sample?.sampledAt,
                                     percentChange: history.percentChange(host: host, metric: "directory", path: resolved),
                                     isUnavailable: sample.map { now().timeIntervalSince($0.sampledAt) > 3600 } ?? false)
        }
    }

    /// Call while observed; no timer or background job scans when this view is closed.
    func refreshIfNeeded(force: Bool = false) async {
        guard !isRefreshing, force || lastAttempt.map({ now().timeIntervalSince($0) >= 900 }) ?? true else { return }
        isRefreshing = true
        lastAttempt = now()
        defer { isRefreshing = false }
        let probe = self.probe
        for index in rows.indices {
            guard !Task.isCancelled else { break }
            let path = rows[index].path
            let bytes = await Task.detached(priority: .background) { probe(path) }.value
            guard !Task.isCancelled else { break }
            if let bytes, bytes >= 0 {
                let timestamp = now()
                if history.record(host: host, metric: "directory", path: path, bytes: bytes, sampledAt: timestamp) {
                    rows[index].bytes = bytes
                    rows[index].sampledAt = timestamp
                    rows[index].percentChange = history.percentChange(host: host, metric: "directory", path: path)
                    rows[index].isUnavailable = false
                }
            } else {
                rows[index].isUnavailable = true
                rows[index].percentChange = nil
            }
        }
    }

    nonisolated static func measure(_ path: String) -> Int64? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil,
              NSClassFromString("XCTest.XCTestCase") == nil,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", "-x", path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return nil }
        guard completed.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            // SIGKILL also bounds a child that ignores termination.
            if completed.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readData(ofLength: 4096), encoding: .utf8),
              let token = text.split(whereSeparator: \.isWhitespace).first,
              let kibibytes = Int64(token), kibibytes >= 0, kibibytes <= Int64.max / 1024 else { return nil }
        return kibibytes * 1024
    }
}
#endif
