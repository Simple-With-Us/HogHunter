import Foundation

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

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.sshRunner()
    }

    /// Stop one process on the server.
    func stop(process: VPSProcess, host: String) async {
        await run(host: host, arguments: [
            "/usr/local/sbin/hoghunter-control", "stop-process",
            "--pid", String(process.pid),
            "--start-time", String(process.startTime ?? 0),
            "--confirm",
        ], describe: "Stopped \(process.name)")
    }

    /// Stop one Coolify workload on the server.
    func stopContainer(named name: String, host: String) async {
        await run(host: host, arguments: [
            "/usr/local/sbin/hoghunter-control", "stop-container",
            "--name", name,
            "--confirm",
        ], describe: "Stopped \(name)")
    }

    private func run(host: String, arguments: [String], describe: String) async {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
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
                lastOutcome = .acted(describe)
            case .some(false):
                lastOutcome = .refused(Self.reason(from: output) ?? "The server refused that.")
            case .none:
                lastOutcome = .acted(describe)
            }
        } catch {
            lastOutcome = .failed((error as NSError).localizedDescription)
        }
    }

    /// The control script answers with JSON: `{"ok": true}` or `{"ok": false,
    /// "reason": "..."}`.  Anything else is treated as a refusal rather than
    /// as a success.
    static func parse(_ output: String) -> Bool? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else { return nil }
        return ok
    }

    static func reason(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String else { return nil }
        return reason
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
/// The reading path and the acting path both go through here, so both use the
/// same host, the same key and the same timeout rules.
enum SSHCommand {
    static func run(host: String, arguments: [String], timeout: TimeInterval) async throws -> String {
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
            host,
        ] + arguments

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
}
