import Combine
import Darwin
import Foundation

enum ServerMaintenanceStrategy: String, CaseIterable, Identifiable, Sendable {
    case packageCache = "package-cache"
    case rotatedLogs = "rotated-logs"
    case buildCache = "docker-build-cache"
    case images = "docker-images"

    var id: String { rawValue }
    static let defaults: [Self] = [.packageCache, .rotatedLogs, .buildCache]
    var title: String {
        switch self {
        case .packageCache: return "Package Cache"
        case .rotatedLogs: return "Rotated Backup Logs"
        case .buildCache: return "Docker Build Cache"
        case .images: return "Unused Docker Images"
        }
    }
}

/// Immutable authorization target: changing settings while a sheet is open
/// cannot retarget its host or its selected work.
struct PendingMaintenanceRequest: Identifiable, Equatable, Sendable {
    enum Mode: String, Sendable { case scan, run }
    let id = UUID()
    let host: String
    let mode: Mode
    let strategies: [ServerMaintenanceStrategy]

    init(host: String, mode: Mode, strategies: [ServerMaintenanceStrategy]) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]")
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.rangeOfCharacter(from: allowed.inverted) == nil,
              !strategies.isEmpty, Set(strategies).count == strategies.count else {
            throw ServerMaintenanceFailure.invalid
        }
        self.host = host
        self.mode = mode
        self.strategies = ServerMaintenanceStrategy.allCases.filter(strategies.contains)
    }

    var includesImages: Bool { strategies.contains(.images) }
    var arguments: [String] {
        var result = ["sudo", "-n", "/usr/local/sbin/hoghunter-maintain", mode.rawValue, "--manual"]
        for strategy in strategies { result += ["--strategy", strategy.rawValue] }
        if mode == .run { result.append("--confirm") }
        return result
    }
}

private enum ServerMaintenanceFailure: Error { case invalid, transport, completionUnconfirmed }

struct ServerMaintenanceResponse: Sendable {
    let exitCode: Int32
    let output: String
}

struct ServerMaintenanceResult: Decodable, Equatable, Sendable {
    struct Disk: Decodable, Equatable, Sendable {
        let freeBytes: Int64
        let totalBytes: Int64
        let usedPercent: Double
        enum CodingKeys: String, CodingKey {
            case freeBytes = "free_bytes", totalBytes = "total_bytes", usedPercent = "used_percent"
        }
        var valid: Bool {
            totalBytes > 0 && freeBytes >= 0 && freeBytes <= totalBytes &&
                usedPercent.isFinite && (0...100).contains(usedPercent)
        }
    }
    struct Lock: Decodable, Equatable, Sendable { let acquired: Bool; let released: Bool? }
    struct Cancellation: Decodable, Equatable, Sendable { let requested: Bool }
    struct Strategy: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let status: String
        let candidateCount: Int64
        let removedCount: Int64
        let attemptedCount: Int64
        let inventoryComplete: Bool?
        enum CodingKeys: String, CodingKey {
            case id, status, candidateCount = "candidate_count", removedCount = "removed_count", attemptedCount = "attempted_count"
            case inventoryComplete = "inventory_complete"
        }

        func eligibilityIsKnown(in resultStatus: String) -> Bool {
            if let inventoryComplete { return inventoryComplete }
            // Legacy error rows have no completeness proof, even with a zero
            // count.  Retain only established successful/planned compatibility.
            return ["ran", "skipped", "planned"].contains(resultStatus) &&
                ["ran", "skipped", "planned"].contains(status)
        }
    }
    let schemaVersion: Int
    let tool: String
    let mode: String
    let manual: Bool?
    let dryRun: Bool
    let pressure: Bool
    let status: String
    private let reason: String?
    let before: Disk
    let after: Disk
    let reclaimedBytes: Int64
    let observedFreeDeltaBytes: Int64
    let removedFileBytes: Int64
    let candidateCount: Int64
    let strategies: [Strategy]
    let lock: Lock
    let cancellation: Cancellation
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", tool, mode, manual, dryRun = "dry_run", pressure, status, reason, before, after
        case reclaimedBytes = "reclaimed_bytes", observedFreeDeltaBytes = "observed_free_delta_bytes"
        case removedFileBytes = "removed_file_bytes", candidateCount = "candidate_count", strategies, lock, cancellation
        case durationSeconds = "duration_seconds"
    }

    static func parse(_ response: ServerMaintenanceResponse, for request: PendingMaintenanceRequest) throws -> Self {
        guard let data = response.output.data(using: .utf8), data.count <= 1_048_576 else {
            throw ServerMaintenanceFailure.invalid
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let successful = ["ran", "skipped", "planned"].contains(value.status)
        guard value.schemaVersion == 1, value.tool == "hoghunter-server-maintenance",
              value.mode == request.mode.rawValue, value.manual == true, !value.dryRun,
              ["ran", "skipped", "planned", "partial", "failed", "cancelled"].contains(value.status),
              response.exitCode == (successful ? 0 : 1), value.before.valid, value.after.valid,
              value.reclaimedBytes >= 0, value.removedFileBytes >= 0, value.candidateCount >= 0,
              value.observedFreeDeltaBytes == value.after.freeBytes - value.before.freeBytes,
              value.durationSeconds.isFinite, (0...110).contains(value.durationSeconds),
              value.strategies.count <= request.strategies.count,
              Set(value.strategies.map(\.id)).count == value.strategies.count else {
            throw ServerMaintenanceFailure.invalid
        }
        var total: Int64 = 0
        for row in value.strategies {
            guard request.strategies.map(\.rawValue).contains(row.id),
                  ["ran", "skipped", "planned", "partial", "failed"].contains(row.status),
                  (0...1_000_000).contains(row.candidateCount), row.removedCount >= 0, row.attemptedCount >= 0,
                  row.removedCount <= row.candidateCount, row.attemptedCount <= row.candidateCount else {
                throw ServerMaintenanceFailure.invalid
            }
            if row.inventoryComplete == false {
                guard ["partial", "failed"].contains(row.status), row.candidateCount == 0,
                      row.removedCount == 0, row.attemptedCount == 0 else {
                    throw ServerMaintenanceFailure.invalid
                }
            }
            total += row.candidateCount
        }
        guard total == value.candidateCount,
              value.status != "cancelled" || value.cancellation.requested,
              value.status != "ran" || (value.lock.acquired && value.lock.released == true &&
                  value.strategies.contains { $0.status == "ran" && ($0.removedCount > 0 || $0.attemptedCount > 0) }),
              !["skipped", "planned"].contains(value.status) || (value.removedFileBytes == 0 && value.reclaimedBytes == 0 &&
                  value.strategies.allSatisfy { $0.removedCount == 0 && $0.attemptedCount == 0 }) else {
            throw ServerMaintenanceFailure.invalid
        }
        let emptyBusy = request.mode == .run && value.status == "skipped" && value.strategies.isEmpty &&
            value.reason == "shared remote cleanup lock busy; no work started" && !value.lock.acquired &&
            value.lock.released == nil && !value.cancellation.requested && value.candidateCount == 0 &&
            value.removedFileBytes == 0 && value.reclaimedBytes == 0
        if !emptyBusy {
            guard Set(value.strategies.map(\.id)) == Set(request.strategies.map(\.rawValue)) else {
                throw ServerMaintenanceFailure.invalid
            }
        }
        if request.mode == .scan {
            guard value.status != "ran", !value.lock.acquired, value.removedFileBytes == 0, value.reclaimedBytes == 0,
                  value.strategies.allSatisfy({ $0.removedCount == 0 && $0.attemptedCount == 0 && $0.status != "ran" }) else {
                throw ServerMaintenanceFailure.invalid
            }
        } else if value.status == "planned" {
            throw ServerMaintenanceFailure.invalid
        }
        return value
    }

    var message: String {
        switch status {
        case "ran": return "Selected server maintenance completed."
        case "planned": return "Read-only scan completed; eligible items are listed below."
        case "skipped": return strategies.isEmpty ? "Server cleanup is busy; no work started." : "No eligible selected items were found."
        case "cancelled": return "Server maintenance was cancelled; some work may have completed."
        case "partial": return "Server maintenance was partial; inspect the server audit before retrying."
        default: return "Server maintenance failed; no complete run is claimed."
        }
    }
}

@MainActor
final class ServerMaintenanceControl: ObservableObject {
    typealias Runner = @Sendable (_ host: String, _ arguments: [String]) async throws -> ServerMaintenanceResponse
    @Published private(set) var isWorking = false
    @Published private(set) var result: ServerMaintenanceResult?
    @Published private(set) var message: String?
    private let runner: Runner

    init(runner: Runner? = nil) { self.runner = runner ?? Self.sshRunner }

    func perform(_ request: PendingMaintenanceRequest, confirmed: Bool = false, imageRemovalConfirmed: Bool = false) async {
        guard !isWorking else { message = "Another server maintenance request is already running."; return }
        guard request.mode != .run || (confirmed && (!request.includesImages || imageRemovalConfirmed)) else {
            message = "Confirm the selected cleanup and any image rollback or download consequences."
            return
        }
        isWorking = true
        result = nil
        message = nil
        defer { isWorking = false }
        do {
            let response = try await runner(request.host, request.arguments)
            let parsed = try ServerMaintenanceResult.parse(response, for: request)
            result = parsed
            message = parsed.message
        } catch ServerMaintenanceFailure.completionUnconfirmed {
            message = request.mode == .run
                ? "Server outcome is unconfirmed; the remote run may continue under its cleanup lock.\u{00A0} Refresh status before retrying."
                : "The server scan outcome is unconfirmed; wait for it to finish before retrying."
        } catch {
            message = request.mode == .run
                ? "Server outcome is unconfirmed; refresh status and inspect the server audit before retrying."
                : "Could not verify server maintenance; check SSH, sudo access and the installed helper."
        }
    }

    nonisolated private static let sshRunner: Runner = { host, arguments in
        guard ApplicationRunMode.current.allowsLiveProbes else { throw ServerMaintenanceFailure.transport }
        let task = Task.detached(priority: .utility) { try MaintenanceSSH.run(host: host, arguments: arguments) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Dedicated fixed-argv transport: bounded stdout in memory, stderr discarded,
/// and a monotonic wall deadline.  It signals only the SSH child it creates.
struct MaintenanceCaptureFailure: Error {
    enum Reason: Equatable { case timeout, outputLimit, cancelled, readFailure, childExitUnconfirmed }
    let reason: Reason
    let childExitConfirmed: Bool
}

enum MaintenanceSSH {
    fileprivate static func run(host: String, arguments: [String]) throws -> ServerMaintenanceResponse {
        do {
            return try capture(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments:
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=3",
                 "-o", "ServerAliveCountMax=2", host] + arguments)
        } catch is MaintenanceCaptureFailure {
            // Even a confirmed local SSH exit cannot prove that a dispatched
            // remote mutation stopped; the server retains its own serialization.
            throw ServerMaintenanceFailure.completionUnconfirmed
        }
    }

    /// Internal fixture seam: tests create only their own harmless local child.
    /// The production entry point above remains behind the XCTest refusal.
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval = 105,
                        maxOutput: Int = 1_048_576, started: @Sendable (Int32) -> Void = { _ in }) throws -> ServerMaintenanceResponse {
        let process = Process()
        let pipe = Pipe()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw ServerMaintenanceFailure.transport }
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        started(process.processIdentifier)
        try? pipe.fileHandleForWriting.close()
        var childExitConfirmed = false
        func observeExit(seconds: TimeInterval) -> Bool {
            if childExitConfirmed { return true }
            // Foundation invokes the handler after its child-exit/reap path;
            // never use an unbounded waitUntilExit here.
            childExitConfirmed = terminated.wait(timeout: .now() + seconds) == .success
            return childExitConfirmed
        }
        func stopOwnedChild() -> Bool {
            if observeExit(seconds: 0) { return true }
            if process.isRunning { process.terminate() }
            if observeExit(seconds: 1) { return true }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return observeExit(seconds: 1)
        }
        let end = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var eof = false
        do {
            while true {
                if Task.isCancelled { throw MaintenanceCaptureFailure.Reason.cancelled }
                if ProcessInfo.processInfo.systemUptime >= end { throw MaintenanceCaptureFailure.Reason.timeout }
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count > 0 {
                    guard output.count + count <= maxOutput else { throw MaintenanceCaptureFailure.Reason.outputLimit }
                    output.append(contentsOf: chunk.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw MaintenanceCaptureFailure.Reason.readFailure }
                if !process.isRunning && eof { break }
                if count <= 0 { Thread.sleep(forTimeInterval: 0.02) }
            }
            guard observeExit(seconds: 1) else { throw MaintenanceCaptureFailure.Reason.childExitUnconfirmed }
            guard let text = String(data: output, encoding: .utf8) else { throw MaintenanceCaptureFailure.Reason.readFailure }
            return ServerMaintenanceResponse(exitCode: process.terminationStatus, output: text)
        } catch {
            let confirmed = stopOwnedChild()
            throw MaintenanceCaptureFailure(reason: (error as? MaintenanceCaptureFailure.Reason) ?? .readFailure,
                                            childExitConfirmed: confirmed)
        }
    }
}

extension MaintenanceCaptureFailure.Reason: Error {}
