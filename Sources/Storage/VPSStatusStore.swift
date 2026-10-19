import Foundation

/// Fetches and caches remote VPS resource snapshots over SSH.
///
/// Owned by `MaintainStore` and consumed by `VPSResourceCardView` in the Maintenance tab.
@MainActor
final class VPSStatusStore: ObservableObject {
    typealias Fetcher = @Sendable (_ host: String) async throws -> VPSStatusSnapshot

    @Published private(set) var snapshot: VPSStatusSnapshot?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var configuredHost: String = ""

    private let fetcher: Fetcher
    private var timer: Timer?
    private var activeFetchTask: Task<Void, Never>?
    /// How many views currently want server readings.  The panel shows a
    /// server strip on its Activity tab and the Server tab shows the full
    /// card, so the store outlives any one of them: polling stops only when
    /// the last owner lets go, never when one of them closes.
    private var pollingOwners: Int = 0

    init(initialHost: String = "", fetcher: Fetcher? = nil) {
        self.configuredHost = initialHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetcher = fetcher ?? Self.sshFetcher()
    }

    func setHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != configuredHost else { return }
        configuredHost = trimmed
        snapshot = nil
        errorMessage = nil
        if !configuredHost.isEmpty {
            fetch(force: true)
        }
    }

    /// Whether the readings are still being fetched.  True while at least one
    /// owner holds a share.
    var isPolling: Bool {
        pollingOwners > 0
    }

    /// Takes a share of the polling.  The first owner starts it; the last one
    /// to let go stops it.  A view that shows server readings acquires on
    /// appear and releases on disappear, so two views showing them at once
    /// cannot switch each other's readings off.
    func acquirePolling() {
        pollingOwners += 1
        if pollingOwners == 1 {
            startPolling()
        }
    }

    /// Gives up a share of the polling.  Polling stops when the last owner
    /// lets go.
    func releasePolling() {
        pollingOwners = max(0, pollingOwners - 1)
        if pollingOwners == 0 {
            stopPolling()
        }
    }

    func startPolling() {
        stopPolling()
        if !configuredHost.isEmpty {
            fetch(force: false)
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetch(force: false)
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        activeFetchTask?.cancel()
        activeFetchTask = nil
        isLoading = false
    }

    func fetch(force: Bool = false) {
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "No remote server configured."
            isLoading = false
            return
        }

        if isLoading { return }

        if !force, let last = lastFetchDate, Date().timeIntervalSince(last) < 60 {
            return
        }

        isLoading = true
        errorMessage = nil

        let fetcher = self.fetcher

        activeFetchTask?.cancel()
        activeFetchTask = Task { [weak self] in
            let result: Result<VPSStatusSnapshot, Error>
            do {
                let snap = try await fetcher(host)
                result = .success(snap)
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            self.isLoading = false
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let snap):
                self.snapshot = snap
                self.errorMessage = nil
                self.lastFetchDate = Date()
            case .failure(let err):
                self.errorMessage = err.localizedDescription
            }
        }
    }

    nonisolated static func sshFetcher() -> Fetcher {
        { host in
            guard !MaintainStore.isRunningUnderTest else {
                throw NSError(domain: "VPSStatusStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH fetcher does not run from unit tests."])
            }
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                throw NSError(domain: "VPSStatusStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "No remote server configured."])
            }

            let errURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hoghunter-vps-\(UUID().uuidString).stderr")
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hoghunter-vps-\(UUID().uuidString).stdout")

            guard FileManager.default.createFile(atPath: errURL.path, contents: nil),
                  FileManager.default.createFile(atPath: outURL.path, contents: nil),
                  let errHandle = try? FileHandle(forWritingTo: errURL),
                  let outHandle = try? FileHandle(forWritingTo: outURL) else {
                throw CocoaError(.fileWriteUnknown)
            }

            return try await withCheckedThrowingContinuation { continuation in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "ServerAliveInterval=3",
                    "-o", "ServerAliveCountMax=2",
                    trimmedHost,
                    "cat /root/vps-storage-status.json"
                ]
                proc.standardOutput = outHandle
                proc.standardError = errHandle

                let resumeLock = NSLock()
                var hasResumed = false

                let timeoutTimer = DispatchSource.makeTimerSource()
                timeoutTimer.schedule(deadline: .now() + 15.0)
                timeoutTimer.setEventHandler {
                    if proc.isRunning {
                        proc.terminate()
                    }
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
                        do {
                            let decoder = JSONDecoder()
                            let snapshot = try decoder.decode(VPSStatusSnapshot.self, from: outData)
                            continuation.resume(returning: snapshot)
                        } catch {
                            continuation.resume(throwing: NSError(
                                domain: "VPSStatusStore",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to decode server snapshot: \(error.localizedDescription)"]
                            ))
                        }
                    } else {
                        let rawErr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let desc = rawErr.isEmpty ? "SSH connection failed (status \(finished.terminationStatus))." : rawErr
                        continuation.resume(throwing: NSError(
                            domain: "VPSStatusStore",
                            code: Int(finished.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: desc]
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
        }
    }
}
