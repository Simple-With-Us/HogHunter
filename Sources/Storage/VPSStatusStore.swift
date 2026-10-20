import Foundation

/// Fetches and caches remote VPS resource snapshots over SSH.
///
/// Owned by `MaintainStore`, and read by the panel's server strip and the
/// panel's Server tab.
@MainActor
final class VPSStatusStore: ObservableObject {
    typealias Fetcher = @Sendable (_ host: String) async throws -> VPSStatusSnapshot

    @Published private(set) var snapshot: VPSStatusSnapshot?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var configuredHost: String = ""

    private let history: SizeGrowthHistory
    private let fetcher: Fetcher
    private var timer: Timer?
    private var activeFetchTask: Task<Void, Never>?

    init(initialHost: String = "", fetcher: Fetcher? = nil, history: SizeGrowthHistory = .shared) {
        self.history = history
        self.configuredHost = initialHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetcher = fetcher ?? Self.sshFetcher()
    }

    /// Sets the host to watch, and starts or stops the readings with it.
    ///
    /// The store owns its polling; the window does not hand out shares.  A
    /// share was the obvious design, but a view's lifetime is not a reliable
    /// signal (a panel that is hidden without being torn down never says so),
    /// and a counter that never comes back down would keep polling forever.
    /// One small file read a minute on the host is a fair price for watching a
    /// machine, and it cannot get stuck.
    func setHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != configuredHost else { return }
        configuredHost = trimmed
        snapshot = nil
        lastFetchDate = nil
        errorMessage = nil
        if !configuredHost.isEmpty {
            startPolling()
            // A new host wants fresh readings now, not in a minute.
            fetch(force: true)
        } else {
            stopPolling()
        }
    }

    /// Whether the readings are being fetched.
    var isPolling: Bool {
        timer != nil
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
            guard !Task.isCancelled, self.configuredHost == host else { return }
            switch result {
            case .success(let snap):
                let history = self.history
                await Task.detached(priority: .utility) {
                    Self.recordSizes(snap, configuredHost: host, history: history)
                }.value
                guard !Task.isCancelled, self.configuredHost == host else { return }
                self.snapshot = snap
                self.errorMessage = nil
                self.lastFetchDate = Date()
            case .failure(let err):
                self.errorMessage = err.localizedDescription
            }
            self.isLoading = false
        }
    }

    private func historyHost(_ source: VPSStatusSnapshot) -> String {
        configuredHost + "|" + source.host
    }

    nonisolated private static func recordSizes(_ source: VPSStatusSnapshot, configuredHost: String, history: SizeGrowthHistory) {
        guard let sampledAt = source.generatedAtDate else { return }
        let host = configuredHost + "|" + source.host
        func observations(_ samples: [VPSSizeSample]?, path: String, bytes: Int64) -> [SizeGrowthSample] {
            var values = (samples ?? []).compactMap { sample -> SizeGrowthSample? in
                let date = Date(timeIntervalSince1970: sample.sampledAt)
                guard sample.path == path, date <= sampledAt,
                      sampledAt.timeIntervalSince(date) <= 172_800 else { return nil }
                return SizeGrowthSample(bytes: sample.bytes, sampledAt: date)
            }
            values.append(SizeGrowthSample(bytes: bytes, sampledAt: sampledAt))
            return values
        }
        for (key, bytes) in source.appDbs ?? [:] {
            history.importSamples(host: host, metric: "database", path: key,
                                  samples: observations(source.databaseSamples, path: key, bytes: bytes))
        }
        for directory in source.largestDirs ?? [] {
            history.importSamples(host: host, metric: "directory", path: directory.path,
                                  samples: observations(source.directorySamples, path: directory.path, bytes: directory.bytes))
        }
    }

    func databasePercentChange(key: String) -> Double? {
        guard let snapshot else { return nil }
        return history.percentChange(host: historyHost(snapshot), metric: "database", path: key)
    }

    func directoryPercentChange(path: String) -> Double? {
        guard let snapshot else { return nil }
        return history.percentChange(host: historyHost(snapshot), metric: "directory", path: path)
    }

    nonisolated static func sshFetcher() -> Fetcher {
        { host in
            guard ApplicationRunMode.current.allowsLiveProbes else {
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

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
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
            } onCancel: {
                // A cancelled read must not leave an ssh process behind: the
                // child is killed here instead of running on until the timeout
                // timer fires.
                if proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }
}
