import Foundation

/// Fetches and caches remote VPS resource snapshots over SSH.
///
/// Owned by `MaintainStore`, and read by the panel's server strip and the
/// panel's Server tab.
@MainActor
final class VPSStatusStore: ObservableObject {
    typealias Fetcher = @Sendable (_ host: String) async throws -> VPSStatusSnapshot
    /// A live CPU read between full snapshots: cheap enough to run on the
    /// Mac sampler's own beat, where the full snapshot is a file the server
    /// rewrites once a minute for itself.
    typealias LiveCpuFetcher = @Sendable (_ host: String) async throws -> VPSCPU

    /// The Mac samples its own CPU every five seconds (HogStore's default
    /// refresh interval); the server's live CPU reads on the same beat, so
    /// the panel's two CPU columns tick together (Jay, 2026-11-20: the
    /// server's CPU must update as often as the Mac's).
    static let liveCpuPollInterval: TimeInterval = 5
    /// A live reading older than this is no longer the server's state now.
    static let liveCpuStaleAfter: TimeInterval = 20

    @Published private(set) var snapshot: VPSStatusSnapshot?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    /// The last read's failure, kept until a read succeeds.  `errorMessage`
    /// clears the moment a retry starts, and a retry against a dead host takes
    /// up to 15 seconds, so a reader that polls would see the failure come and
    /// go.  The phone polls.
    @Published private(set) var lastReadError: String?
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var configuredHost: String = ""

    /// The server's own CPU history, kept the way the Mac keeps its own: one
    /// mean per minute.  Without it the server's CPU is a single number with
    /// no shape, and the two machines cannot be read side by side.
    @Published private(set) var cpuHistory = CpuMinuteHistory()

    /// The server's CPU right now, read live between the once-a-minute
    /// snapshots.  The panel shows this while it is fresh and falls back to
    /// the snapshot's CPU when it is not.
    @Published private(set) var liveCpu: VPSCPU?
    @Published private(set) var liveCpuAt: Date?

    /// Bumped when a reading crosses the staleness deadline with no new
    /// fetch landing, purely so observers re-render: `isStale` turns on
    /// wall-clock time alone, and without a published change at that moment
    /// SwiftUI keeps showing the reading as current until the next poll.
    @Published private(set) var stalenessRevision = 0

    private let history: SizeGrowthHistory
    private let fetcher: Fetcher
    private let liveCpuFetcher: LiveCpuFetcher
    private var timer: Timer?
    private var stalenessTimer: Timer?
    private var liveCpuTimer: Timer?
    private var liveStalenessTimer: Timer?
    private var activeFetchTask: Task<Void, Never>?
    private var activeLiveCpuTask: Task<Void, Never>?
    /// A forced read asked for while another was in flight.  It runs once
    /// that read ends, so a Refresh never lands on a read that started before
    /// it and is silently dropped.  Several asks while busy make one read.
    private(set) var hasQueuedForcedFetch = false

    init(initialHost: String = "", fetcher: Fetcher? = nil, liveCpuFetcher: LiveCpuFetcher? = nil, history: SizeGrowthHistory = .shared) {
        self.history = history
        self.configuredHost = initialHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetcher = fetcher ?? Self.sshFetcher()
        self.liveCpuFetcher = liveCpuFetcher ?? Self.liveCpuSSHFetcher()
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
        lastReadError = nil
        cancelStalenessTimer()
        cancelLiveStalenessTimer()
        cpuHistory = CpuMinuteHistory()
        liveCpu = nil
        liveCpuAt = nil
        if !configuredHost.isEmpty {
            // A new host wants fresh readings now, not in a minute.  The
            // polling start reads at once, because the last fetch time was
            // just cleared; a second, forced fetch here would only be queued
            // behind it and read the host twice.
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Whether the readings are being fetched.
    var isPolling: Bool {
        timer != nil
    }

    /// Whether the snapshot on screen is an old reading rather than the
    /// server's state now: a snapshot exists, but the latest refresh failed,
    /// or none has landed within two poll cycles.  Views mark the server's
    /// numbers stale while this holds, so an old reading cannot present as
    /// live data — the failure mode of 2026-11-04, when a dead SSH socket
    /// froze the panel on a full-disk reading taken during an incident,
    /// hours after the space had been freed.
    var isStale: Bool {
        guard snapshot != nil else { return false }
        if errorMessage != nil { return true }
        guard let lastFetchDate else { return true }
        return Date().timeIntervalSince(lastFetchDate) > 150
    }

    /// Whether the live CPU reading on screen is an old one: a reading
    /// exists, but no fresh probe has landed within a few poll beats.  The
    /// same wall-clock caveat as `isStale` applies, and the live staleness
    /// timer bumps `stalenessRevision` at the deadline for the same reason.
    var isLiveCpuStale: Bool {
        guard liveCpu != nil, let liveCpuAt else { return false }
        return Date().timeIntervalSince(liveCpuAt) > Self.liveCpuStaleAfter
    }

    /// The CPU reading the panel shows: the live probe while it is fresh,
    /// else the full snapshot's CPU, which is up to a minute old but never
    /// invented.
    var displayCpu: VPSCPU? {
        if let liveCpu, !isLiveCpuStale { return liveCpu }
        return snapshot?.cpu
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

        let lt = Timer(timeInterval: Self.liveCpuPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchLiveCpu()
            }
        }
        lt.tolerance = 1
        RunLoop.main.add(lt, forMode: .common)
        liveCpuTimer = lt
        // A fresh host wants a live reading now, on the same terms the
        // snapshot gets one.
        if !configuredHost.isEmpty {
            fetchLiveCpu()
        }
    }

    func stopPolling() {
        hasQueuedForcedFetch = false
        timer?.invalidate()
        timer = nil
        liveCpuTimer?.invalidate()
        liveCpuTimer = nil
        cancelStalenessTimer()
        cancelLiveStalenessTimer()
        activeFetchTask?.cancel()
        activeFetchTask = nil
        activeLiveCpuTask?.cancel()
        activeLiveCpuTask = nil
        liveCpu = nil
        liveCpuAt = nil
        isLoading = false
    }

    /// Arms the one-shot timer that publishes a change when the current
    /// reading crosses the staleness deadline in `isStale`, so the stale
    /// markers appear at the deadline instead of at the next poll tick.
    /// Internal rather than private so a test can arm it with a short
    /// interval; production arms it from each successful fetch with the
    /// time left until that reading ages out.
    func scheduleStalenessFlip(after interval: TimeInterval) {
        cancelStalenessTimer()
        let t = Timer(timeInterval: max(0.001, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stalenessTimer = nil
                self.stalenessRevision &+= 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        stalenessTimer = t
    }

    private func cancelStalenessTimer() {
        stalenessTimer?.invalidate()
        stalenessTimer = nil
    }

    /// Arms the one-shot timer that re-renders observers when the live CPU
    /// reading crosses its own, much shorter staleness deadline.  Same shape
    /// as `scheduleStalenessFlip`, which exists for the full snapshot, and
    /// internal rather than private so a test can arm it directly.
    func scheduleLiveCpuStalenessFlip(after interval: TimeInterval) {
        cancelLiveStalenessTimer()
        let t = Timer(timeInterval: max(0.001, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.liveStalenessTimer = nil
                self.stalenessRevision &+= 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        liveStalenessTimer = t
    }

    private func cancelLiveStalenessTimer() {
        liveStalenessTimer?.invalidate()
        liveStalenessTimer = nil
    }

    func fetch(force: Bool = false) {
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "No remote server configured."
            isLoading = false
            return
        }

        if isLoading {
            if force { hasQueuedForcedFetch = true }
            return
        }

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
                if let cpu = snap.cpu {
                    self.cpuHistory.record(percent: cpu.pct, at: Date())
                }
                self.errorMessage = nil
                self.lastReadError = nil
                let fetchedAt = Date()
                self.lastFetchDate = fetchedAt
                self.scheduleStalenessFlip(after: fetchedAt.addingTimeInterval(150).timeIntervalSinceNow)
            case .failure(let err):
                // The error itself is published, so observers re-render and
                // read `isStale` as true without waiting for the timer.
                self.cancelStalenessTimer()
                self.errorMessage = err.localizedDescription
                self.lastReadError = err.localizedDescription
            }
            self.isLoading = false
            if self.hasQueuedForcedFetch {
                self.hasQueuedForcedFetch = false
                self.fetch(force: true)
            }
        }
    }

    /// One live read of the server's CPU, on the Mac sampler's five-second
    /// beat.  Cheap by design: two aggregate /proc/stat lines one second
    /// apart, the load average and the core count, over the connection the
    /// full snapshot already uses.  The once-a-minute snapshot stays the
    /// source for memory, disks, databases and the process table.
    func fetchLiveCpu() {
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        // A probe still in flight is skipped, not stacked: the next tick
        // reads instead, so a slow server cannot queue reads against itself.
        guard activeLiveCpuTask == nil else { return }
        let fetcher = liveCpuFetcher
        activeLiveCpuTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeLiveCpuTask = nil }
            do {
                let cpu = try await fetcher(host)
                guard !Task.isCancelled, self.configuredHost == host else { return }
                self.liveCpu = cpu
                let readAt = Date()
                self.liveCpuAt = readAt
                self.cpuHistory.record(percent: cpu.pct, at: readAt)
                self.scheduleLiveCpuStalenessFlip(after: Self.liveCpuStaleAfter)
            } catch {
                // A failed probe changes nothing on its own: the last good
                // reading stays until it ages past liveCpuStaleAfter, when
                // the stale marker takes over and the snapshot's CPU steps
                // back in through displayCpu.
            }
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

    /// The fetcher the store uses live: one read over the app's SSH
    /// connection (see `rawSSHFetcher`), with dead-socket recovery around it.
    ///
    /// When the connection's master has died, the read fails with a mux
    /// error — a dead local socket, not an unreachable server.  The recovery
    /// discards the dead master first and then runs the read once more, over
    /// the fresh connection that attempt creates; no read is ever retried
    /// over the dead socket or its path.  Recovery therefore happens on the
    /// ordinary poll cycle, and the Retry button gets it for free because it
    /// calls this same fetcher.  Any other failure is reported as produced.
    nonisolated static func sshFetcher() -> Fetcher {
        let read = rawSSHFetcher()
        return { host in
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await SSHConnection.retryingOnceOnDeadSocket(
                attempt: { try await read(trimmedHost) },
                discard: { await SSHConnection.invalidate(host: trimmedHost) }
            )
        }
    }

    /// One command over the app's SSH connection: the process machinery the
    /// snapshot read and the live CPU probe share.  It returns what the
    /// command printed; a nonzero exit throws with the command's own stderr.
    /// Dead-socket recovery is the caller's wrapper's call, not this one's.
    /// The hard timeout kills a hung read, and a cancelled read kills the
    /// ssh child rather than leaving it to run on until the timeout fires.
    nonisolated private static func runSSH(host: String, remoteCommand: String, hardTimeout: TimeInterval) async throws -> Data {
        guard ApplicationRunMode.current.allowsLiveProbes else {
            throw NSError(domain: "VPSStatusStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH fetcher does not run from unit tests."])
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
        ] + SSHConnection.connectionOptions(forHost: host) + [
            host,
            remoteCommand,
        ]

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                proc.standardOutput = outHandle
                proc.standardError = errHandle

                let resumeLock = NSLock()
                var hasResumed = false

                let timeoutTimer = DispatchSource.makeTimerSource()
                timeoutTimer.schedule(deadline: .now() + hardTimeout)
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
                        continuation.resume(returning: outData)
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

    /// One read of the server's status file over the app's SSH connection,
    /// with no recovery of its own: a failure is reported exactly as ssh
    /// produced it, and `sshFetcher` above decides whether the failure is a
    /// dead socket worth discarding and retrying once.
    nonisolated private static func rawSSHFetcher() -> Fetcher {
        { host in
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                throw NSError(domain: "VPSStatusStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "No remote server configured."])
            }
            let data = try await runSSH(host: trimmedHost, remoteCommand: "cat /root/vps-storage-status.json", hardTimeout: 15.0)
            do {
                return try JSONDecoder().decode(VPSStatusSnapshot.self, from: data)
            } catch {
                throw NSError(domain: "VPSStatusStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decode server snapshot: \(error.localizedDescription)"])
            }
        }
    }

    /// The live CPU probe the store uses live: one read over the app's SSH
    /// connection, with the same dead-socket recovery the full snapshot
    /// gets.
    nonisolated static func liveCpuSSHFetcher() -> LiveCpuFetcher {
        let read = liveCpuRawSSHFetcher()
        return { host in
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await SSHConnection.retryingOnceOnDeadSocket(
                attempt: { try await read(trimmedHost) },
                discard: { await SSHConnection.invalidate(host: trimmedHost) }
            )
        }
    }

    /// Two aggregate /proc/stat lines one second apart, the load average and
    /// the core count: everything the live reading needs, nothing else.  The
    /// one-second window mirrors the server watch's own "proc-stat tick
    /// delta 1s", so the live number and the snapshot's number mean the same
    /// thing.
    nonisolated private static func liveCpuRawSSHFetcher() -> LiveCpuFetcher {
        { host in
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                throw NSError(domain: "VPSStatusStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "No remote server configured."])
            }
            let data = try await runSSH(
                host: trimmedHost,
                remoteCommand: "grep '^cpu ' /proc/stat; sleep 1; grep '^cpu ' /proc/stat; echo ---; cat /proc/loadavg; nproc",
                hardTimeout: 10.0
            )
            guard let text = String(data: data, encoding: .utf8), let cpu = parseLiveCpu(text) else {
                throw NSError(domain: "VPSStatusStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to decode the server's live CPU reading."])
            }
            return cpu
        }
    }

    /// Turns the live probe's printout into a reading: the busy share of the
    /// window between the two aggregate /proc/stat lines, the load average
    /// and the core count.  Busy is every tick but idle, iowait included —
    /// the same accounting the server watch's snapshot CPU uses (its
    /// CPU_PCT is (1 - idle / total) over the same one-second window).  A
    /// short, non-numeric or reset window is no reading at all, never a
    /// fictitious zero.
    nonisolated static func parseLiveCpu(_ text: String) -> VPSCPU? {
        var statLines: [[Double]] = []
        var load1: Double?
        var cores: Int?
        var pastMarker = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "---" {
                pastMarker = true
                continue
            }
            if !pastMarker, line.hasPrefix("cpu ") {
                let tokens = line.dropFirst(4).split(whereSeparator: \.isWhitespace)
                let fields = tokens.compactMap { Double($0) }
                guard fields.count == tokens.count, fields.count >= 5 else { continue }
                statLines.append(fields)
                continue
            }
            if pastMarker {
                if load1 == nil {
                    load1 = line.split(whereSeparator: \.isWhitespace).first.flatMap { Double($0) }
                    continue
                }
                if cores == nil {
                    cores = Int(line)
                }
            }
        }
        guard statLines.count >= 2 else { return nil }
        func busyAndTotal(_ f: [Double]) -> (busy: Double, total: Double) {
            let total = f[0] + f[1] + f[2] + f[3] + f[4] + (f.count > 5 ? f[5] : 0) + (f.count > 6 ? f[6] : 0) + (f.count > 7 ? f[7] : 0)
            return (total - f[3], total)
        }
        let before = busyAndTotal(statLines[0])
        let after = busyAndTotal(statLines[1])
        let busyDelta = after.busy - before.busy
        let totalDelta = after.total - before.total
        guard totalDelta > 0, busyDelta >= 0 else { return nil }
        let pct = min(100, max(0, busyDelta / totalDelta * 100))
        return VPSCPU(pct: pct, load1: load1 ?? 0, cores: cores ?? 0, source: "live proc-stat tick delta 1s")
    }
}
