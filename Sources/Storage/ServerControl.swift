import Foundation
import CoreFoundation

/// Acting on the server: stopping a process, or stopping a Coolify workload.
///
/// The server answers through `hoghunter-control`, which it runs as root.
/// The command names the process by its identity -- the pid and the start
/// time the collector read -- so a pid that was recycled between the reading
/// and the click is refused instead of signalled.  The server also keeps the
/// infrastructure that holds the host up out of reach, and writes every
/// action to a root-only audit log.
///
/// Nothing here runs from a unit test: the fetcher is injected, and the
/// default one refuses to run under XCTest.
@MainActor
final class ServerControl: ObservableObject {
    enum Outcome: Equatable {
        case acted(String)
        case refused(String)
        case failed(String)

        var message: String {
            switch self {
            case .acted(let what): return what
            case .refused(let why): return why
            case .failed(let why): return why
            }
        }
    }

    /// The command the server runs.  Injected so a test can answer without a
    /// server, and so the real path is never run by accident.
    typealias Runner = @Sendable (_ host: String, _ arguments: [String]) async throws -> String

    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var isWorking = false
    @Published private(set) var lastSampleText: String?

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.sshRunner()
    }

    /// Each mutation is confirmed by the calling UI, then rechecked on the host.
    func stop(process: VPSProcess, host: String, force: Bool = false,
              allowWorkloadInterruption: Bool = false) async {
        await processAction(force ? "force-quit" : "quit", process: process, host: host,
                            allowWorkloadInterruption: allowWorkloadInterruption)
    }

    func tame(process: VPSProcess, host: String, allowWorkloadInterruption: Bool = false) async {
        await processAction("tame", process: process, host: host, allowWorkloadInterruption: allowWorkloadInterruption)
    }

    func untame(process: VPSProcess, host: String, allowWorkloadInterruption: Bool = false) async {
        await processAction("untame", process: process, host: host, allowWorkloadInterruption: allowWorkloadInterruption)
    }

    func sample(process: VPSProcess, host: String) async {
        lastSampleText = nil
        await processAction("sample", process: process, host: host, allowWorkloadInterruption: false)
    }

    private func processAction(_ action: String, process: VPSProcess, host: String,
                               allowWorkloadInterruption: Bool) async {
        guard process.can(action: action), let bootID = process.bootID, let start = process.startTime else {
            lastOutcome = .refused(process.protectionReason ?? "Refresh the server snapshot for a current process identity.")
            return
        }
        let verb = ["quit": "stop-process", "force-quit": "stop-process", "tame": "tame-process",
                    "untame": "untame-process", "sample": "sample-process"][action]!
        var arguments = ["sudo", "-n", "/usr/local/sbin/hoghunter-control", verb,
                         "--pid", String(process.pid), "--start-time", String(start), "--boot-id", bootID, "--confirm"]
        if action == "force-quit" { arguments.append("--force") }
        if allowWorkloadInterruption { arguments.append("--allow-workload-interruption") }
        let descriptions = ["quit": "Asked \(process.name) to quit", "force-quit": "Force quit \(process.name)",
                            "tame": "Tamed \(process.name)", "untame": "Restored priority for \(process.name)",
                            "sample": "Sampled \(process.name) for 3 seconds"]
        await run(host: host, arguments: arguments, describe: descriptions[action]!, sample: action == "sample")
    }

    func stop(resource: VPSCoolifyResource, host: String, allowWorkloadInterruption: Bool = false) async {
        await workloadAction("stop", resource: resource, host: host, allowWorkloadInterruption: allowWorkloadInterruption)
    }

    func restart(resource: VPSCoolifyResource, host: String, allowWorkloadInterruption: Bool = false) async {
        await workloadAction("restart", resource: resource, host: host, allowWorkloadInterruption: allowWorkloadInterruption)
    }

    private func workloadAction(_ action: String, resource: VPSCoolifyResource, host: String,
                                allowWorkloadInterruption: Bool) async {
        guard allowWorkloadInterruption else {
            lastOutcome = .refused("Confirm that this action interrupts the server workload.")
            return
        }
        guard resource.can(action: action), let identity = resource.containerID, let started = resource.startedAt else {
            lastOutcome = .refused(resource.protectionReason ?? "Refresh the server snapshot for a current workload identity.")
            return
        }
        await run(host: host, arguments: ["sudo", "-n", "/usr/local/sbin/hoghunter-control", action + "-container",
                                         "--name", resource.stopName, "--container-id", identity, "--started-at", started,
                                         "--confirm", "--allow-workload-interruption"],
                  describe: action == "stop" ? "Stopped \(resource.name)" : "Restarted \(resource.name)")
    }

    /// Legacy name-only calls cannot authorize a mutation after this upgrade.
    func stopContainer(named name: String, host: String) async {
        lastOutcome = .refused("Refresh the server snapshot for a current workload identity.")
    }

    private func run(host: String, arguments: [String], describe: String, sample: Bool = false) async {
        guard !isWorking else {
            lastOutcome = .refused("Another server action is already running.")
            return
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            lastOutcome = .failed("No remote server configured.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let output = try await runner(trimmed, arguments)
            let parsed = Self.parse(output)
            switch parsed {
            case .some(true):
                if sample {
                    guard let text = Self.sampleText(from: output) else {
                        lastOutcome = .failed("The server returned an invalid process sample.")
                        return
                    }
                    lastSampleText = text
                }
                lastOutcome = .acted(describe)
            case .some(false):
                lastOutcome = .refused(Self.reason(from: output) ?? "The server refused that.")
            case .none:
                lastOutcome = .failed("The server returned an invalid control response.")
            }
        } catch {
            lastOutcome = .failed((error as NSError).localizedDescription)
        }
    }

    /// The control script answers with JSON: `{"ok": true}` or `{"ok": false,
    /// "reason": "..."}`.  Anything else is treated as a refusal rather than
    /// as a success.
    static func parse(_ output: String) -> Bool? {
        guard let data = output.data(using: .utf8), data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID() else { return nil }
        return ok.boolValue
    }

    static func reason(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String else { return nil }
        return reason
    }

    static func sampleText(from output: String) -> String? {
        guard let data = output.data(using: .utf8), data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["action"] as? String == "sample",
              let sample = object["sample"] as? [String: Any],
              let pid = sample["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(), pid.intValue > 1,
              let duration = sample["duration_seconds"] as? NSNumber,
              CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue >= 0.1, duration.doubleValue <= 10,
              let formatted = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    /// Runs the command over the same SSH path the readings use.
    nonisolated static func sshRunner() -> Runner {
        { host, arguments in
            guard ApplicationRunMode.current.allowsLiveProbes else {
                throw NSError(domain: "ServerControl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "SSH runner does not run from unit tests."])
            }
            return try await SSHCommand.run(host: host, arguments: arguments, timeout: 30)
        }
    }
}

/// One SSH command, one result.
///
/// The acting path goes through here, and the reading path's fetcher in
/// `VPSStatusStore` is built the same way: both run over the app's one SSH
/// connection (see `SSHConnection`), so both use the same host, the same key
/// and the same timeout rules.
enum SSHCommand {
    /// Runs one command exactly once.  This is the acting path — its
    /// commands stop and restart workloads — so it never re-dispatches:
    /// when the connection master has died, the remote helper may already
    /// have applied the action before the channel broke, and running the
    /// command again could apply it twice.  A dead-socket failure instead
    /// discards the dead master and propagates, so the action's outcome is
    /// reported as it stands and the next command the user asks for runs
    /// over a fresh connection.  The reading path is the one that retries,
    /// because a read changes nothing (see `VPSStatusStore.sshFetcher`).
    /// A control-script refusal is an answer, not an error, so it returns
    /// from the attempt untouched; any other failure propagates exactly as
    /// produced.
    static func run(host: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        do {
            return try await runOnce(host: host, arguments: arguments, timeout: timeout)
        } catch {
            if SSHConnection.isDeadSocketFailure(error) {
                await SSHConnection.invalidate(host: host)
            }
            throw error
        }
    }

    private static func runOnce(host: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoghunter-ssh-\(UUID().uuidString).stderr")
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoghunter-ssh-\(UUID().uuidString).stdout")

        guard FileManager.default.createFile(atPath: errURL.path, contents: nil),
              FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let errHandle = try? FileHandle(forWritingTo: errURL),
              let outHandle = try? FileHandle(forWritingTo: outURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
        ] + SSHConnection.connectionOptions(forHost: host) + [
            host,
        ] + arguments.map(Self.shellQuote)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                proc.standardOutput = outHandle
                proc.standardError = errHandle

                let resumeLock = NSLock()
                var hasResumed = false

                let timeoutTimer = DispatchSource.makeTimerSource()
                timeoutTimer.schedule(deadline: .now() + timeout)
                timeoutTimer.setEventHandler {
                    if proc.isRunning { proc.terminate() }
                }
                timeoutTimer.resume()

                proc.terminationHandler = { finished in
                    timeoutTimer.cancel()
                    try? outHandle.close()
                    try? errHandle.close()
                    let outData = (try? Data(contentsOf: outURL)) ?? Data()
                    let errData = (try? Data(contentsOf: errURL)) ?? Data()
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)

                    resumeLock.lock()
                    if hasResumed {
                        resumeLock.unlock()
                        return
                    }
                    hasResumed = true
                    resumeLock.unlock()

                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
                    } else {
                        let outText = String(data: outData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // The control script answers refusals as JSON on
                        // stdout and exits non-zero.  That answer belongs to
                        // the caller, which reports the reason, so hand it
                        // back instead of failing with the bare exit status.
                        if !outText.isEmpty, Self.isControlAnswer(outText, refusalOnly: true) {
                            continuation.resume(returning: outText)
                            return
                        }
                        let rawErr = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let description = rawErr.isEmpty
                            ? "SSH command failed (status \(finished.terminationStatus))."
                            : rawErr
                        continuation.resume(throwing: NSError(
                            domain: "SSHCommand",
                            code: Int(finished.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: description]
                        ))
                    }
                }

                do {
                    try proc.run()
                } catch {
                    timeoutTimer.cancel()
                    try? outHandle.close()
                    try? errHandle.close()
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)

                    resumeLock.lock()
                    let already = hasResumed
                    hasResumed = true
                    resumeLock.unlock()

                    if !already {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Quote one remote argument for the shell ssh runs on the server: ssh
    /// joins the remote command with spaces, so a display name carrying
    /// spaces would otherwise split into several arguments.
    static func shellQuote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+=/:.,@%"))
        if argument.rangeOfCharacter(from: safe.inverted) == nil { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether stdout is the control script's JSON answer (`{"ok": ...}`),
    /// rather than stray output around a transport failure.
    static func isControlAnswer(_ text: String, refusalOnly: Bool = false) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID() else { return false }
        return !refusalOnly || !ok.boolValue
    }
}
