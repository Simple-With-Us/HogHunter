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
                        if !outText.isEmpty, Self.isControlAnswer(outText) {
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
    static func isControlAnswer(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] is Bool else { return false }
        return true
    }
}
