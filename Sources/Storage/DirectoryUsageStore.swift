#if os(macOS)
import Foundation
import Combine

struct DirectoryUsageRow: Identifiable, Equatable {
    var id: String { path }
    let title: String
    let path: String
    let displayPath: String
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
            return DirectoryUsageRow(title: title, path: resolved, displayPath: path, bytes: sample?.bytes, sampledAt: sample?.sampledAt,
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
            let displayPath = rows[index].displayPath
            let bytes = await Task.detached(priority: .background) { probe(displayPath) }.value
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

    /// Enumerate only two layout levels, never repository contents or recursive links.
    /// `du` does not follow child symlinks, so external lane targets need explicit roots.
    nonisolated static func measurementRoots(_ path: String, includeLaneLinks: Bool) -> [String]? {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard includeLaneLinks else { return [base.path] }
        func contains(_ parent: String, _ child: String) -> Bool {
            parent == child || child.hasPrefix(parent + "/")
        }
        var external: [String] = []
        do {
            let children = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard children.count <= 2048 else { return nil }
            var candidates = children
            for child in children {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    let nested = try manager.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isSymbolicLinkKey])
                    guard nested.count <= 4096 else { return nil }
                    candidates.append(contentsOf: nested)
                    guard candidates.count <= 8192 else { return nil }
                }
            }
            for child in candidates {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink == true else { continue }
                let target = child.resolvingSymlinksInPath().standardizedFileURL.path
                var directory: ObjCBool = false
                guard manager.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else { continue }
                // Local aliases are already counted; ancestor links would traverse unrelated data.
                guard !contains(base.path, target), !contains(target, base.path) else { continue }
                if external.contains(where: { contains($0, target) }) { continue }
                external.removeAll(where: { contains(target, $0) })
                external.append(target)
                guard external.count <= 128 else { return nil }
            }
        } catch { return nil }
        return [base.path] + external.sorted()
    }

    nonisolated static func measuredBytes(_ output: String, roots: [String]) -> Int64? {
        var values: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let kibibytes = Int64(fields[0]), kibibytes >= 0,
                  roots.contains(String(fields[1])), values[String(fields[1])] == nil,
                  kibibytes <= Int64.max / 1024 else { return nil }
            values[String(fields[1])] = kibibytes * 1024
        }
        guard values.count == roots.count else { return nil }
        var total: Int64 = 0
        for value in values.values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    nonisolated static func measure(_ path: String) -> Int64? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil,
              NSClassFromString("XCTest.XCTestCase") == nil,
              let roots = measurementRoots(path, includeLaneLinks: URL(fileURLWithPath: path).lastPathComponent == "lanes"),
              roots.allSatisfy({ !$0.contains("\n") && !$0.contains("\t") }) else { return nil }
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("hoghunter-du-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", "/usr/bin/du", "-sk", "-x"] + roots
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return nil }
        let deadline: TimeInterval = roots.count > 1 ? 120 : 8
        guard completed.wait(timeout: .now() + deadline) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return measuredBytes(text, roots: roots)
    }
}
#endif
