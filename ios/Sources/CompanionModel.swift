import Foundation
import Network
import Observation

struct SavedMac: Codable, Equatable {
    var peerID: String
    var name: String
    var token: String
    var remoteHost: String? = nil
    var remotePort: Int? = nil
}

struct DiscoveredMac: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var endpoint: NWEndpoint

    static func == (lhs: DiscoveredMac, rhs: DiscoveredMac) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

enum CompanionClientError: Error, Equatable {
    case unauthorized
    case badResponse
    case timedOut
}

/// Finds Hog Hunter on the Wi-Fi or connects remotely via Tailscale / Domain.
@MainActor
@Observable
final class CompanionModel {
    private(set) var discovered: [DiscoveredMac] = []
    private(set) var snapshot: CompanionSnapshot?
    private(set) var phase: Phase = .looking
    private(set) var saved: SavedMac?
    var codeDraft = ""
    var codeError: String?
    var isSubmittingCode = false
    var isCleaning = false
    var lastCleanResult: CompanionCleanResponse?
    var cleanError: String?
    var showCleanDialogRequested = false
    var statusLine = "Looking for Hog Hunter on this Wi-Fi."
    var isDemoMode = false

    var isRemoteSheetPresented = false
    var remoteHostDraft = ""
    var remotePortDraft = "24240"
    var remoteTokenDraft = ""
    var remoteNameDraft = ""
    var remoteConnectError: String?
    var isConnectingRemote = false

    private var browser: NWBrowser?
    private var poll: Task<Void, Never>?
    private var started = false
    private var didBrowse = false
    private let defaultsKey = "hoghunter.companion.saved"
    private let appGroupSuite = "group.com.simplewithus.hoghunter"

    enum Phase: Equatable {
        case looking
        case choose
        case code(String)
        case live
        case offline
    }

    func start() {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.arguments.contains("-HogHunterSample") {
            snapshot = Self.sample
            phase = .live
            saved = SavedMac(peerID: "sample", name: "This Mac", token: "SAMPLE")
            return
        }
        saved = loadSaved()
        startBrowser()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func select(_ mac: DiscoveredMac) {
        codeDraft = ""
        codeError = nil
        phase = .code(mac.id)
    }

    func cancelCode() {
        codeError = nil
        reconcile()
    }

    func submitCode() async {
        guard case let .code(peerID) = phase, let mac = discovered.first(where: { $0.id == peerID }) else { return }
        let token = codeDraft.uppercased().filter { CompanionToken.alphabet.contains($0) }
        guard token.count >= 8 else {
            codeError = "Enter the 8 character code from Hog Hunter Settings on your Mac."
            return
        }
        isSubmittingCode = true
        defer { isSubmittingCode = false }
        do {
            let next = try await Self.fetch(endpoint: mac.endpoint, token: token)
            saved = SavedMac(peerID: mac.id, name: mac.name, token: token)
            persistSaved()
            snapshot = next
            codeError = nil
            phase = .live
        } catch CompanionClientError.unauthorized {
            codeError = "That code does not match this Mac."
        } catch {
            codeError = "The Mac did not answer.  Check that Share With iPhone is on."
        }
    }

    func forget() {
        saved = nil
        snapshot = nil
        codeDraft = ""
        codeError = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        reconcile()
    }

    func enterDemoMode() {
        isDemoMode = true
        snapshot = Self.sample
        phase = .live
    }

    func exitDemoMode() {
        isDemoMode = false
        snapshot = nil
        reconcile()
    }

    func quitProcess(pid: Int32, force: Bool = false) async -> CompanionQuitResponse {
        if isDemoMode {
            let targetName = snapshot?.rows.first(where: { $0.pid == pid })?.name ?? "Process"
            if let index = snapshot?.rows.firstIndex(where: { $0.pid == pid }) {
                snapshot?.rows.remove(at: index)
            }
            return CompanionQuitResponse(
                status: force ? "forced" : "asked",
                pid: pid,
                name: targetName,
                message: "\(force ? "Force quit" : "Quit") command delivered to Mac.",
                error: nil
            )
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            return CompanionQuitResponse(
                status: "failed",
                pid: pid,
                name: "",
                message: nil,
                error: "Not connected to Mac."
            )
        }
        do {
            let resp = try await CompanionConnection.triggerQuit(endpoint: endpoint, token: saved.token, pid: pid, force: force)
            Task { await refresh() }
            return resp
        } catch {
            return CompanionQuitResponse(
                status: "failed",
                pid: pid,
                name: "",
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    func mac(for peerID: String) -> DiscoveredMac? {
        discovered.first { $0.id == peerID }
    }

    private func activeEndpoint(for saved: SavedMac) -> NWEndpoint? {
        if let mac = discovered.first(where: { $0.id == saved.peerID }) {
            return mac.endpoint
        }
        if let host = saved.remoteHost, let port = NWEndpoint.Port(rawValue: UInt16(saved.remotePort ?? 24240)) {
            return NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return nil
    }

    func connectRemote() async {
        let host = remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            remoteConnectError = "Enter a Tailscale MagicDNS name, IP address, or domain."
            return
        }
        let portNum = Int(remotePortDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 24240
        let token = remoteTokenDraft.uppercased().filter { CompanionToken.alphabet.contains($0) }
        guard token.count >= 8 else {
            remoteConnectError = "Enter the 8 character pairing code from Mac Settings."
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portNum)) else {
            remoteConnectError = "Invalid port number."
            return
        }

        isConnectingRemote = true
        remoteConnectError = nil
        defer { isConnectingRemote = false }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        do {
            let fetched = try await Self.fetch(endpoint: endpoint, token: token)
            let trimmedName = remoteNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedName.isEmpty ? fetched.hostName : trimmedName
            let peerID = "remote-\(host):\(portNum)"
            saved = SavedMac(peerID: peerID, name: displayName, token: token, remoteHost: host, remotePort: portNum)
            persistSaved()
            snapshot = fetched
            phase = .live
            statusLine = "\(displayName) (Remote)"
            isRemoteSheetPresented = false
            if let data = try? CompanionJSON.encode(fetched) {
                UserDefaults(suiteName: appGroupSuite)?.set(data, forKey: "last_snapshot")
            }
        } catch CompanionClientError.unauthorized {
            remoteConnectError = "Pairing code does not match this Mac."
        } catch {
            remoteConnectError = "Could not connect to \(host):\(portNum). Check that Hog Hunter is running on the Mac and the port is reachable."
        }
    }

    private func refresh() async {
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            if didBrowse, let saved, saved.remoteHost == nil, discovered.first(where: { $0.id == saved.peerID }) == nil {
                if phase != .code(saved.peerID) {
                    phase = .offline
                    statusLine = "Can't see \(saved.name) on this Wi-Fi."
                }
            }
            return
        }
        if case .code = phase { return }
        do {
            let fetched = try await Self.fetch(endpoint: endpoint, token: saved.token)
            snapshot = fetched
            phase = .live
            statusLine = saved.remoteHost != nil ? "\(saved.name) (Remote)" : saved.name
            // Persist for iOS WidgetKit extension
            if let data = try? CompanionJSON.encode(fetched) {
                UserDefaults(suiteName: appGroupSuite)?.set(data, forKey: "last_snapshot")
            }
        } catch CompanionClientError.unauthorized {
            codeError = "The code no longer matches.  Enter the code from Hog Hunter Settings on your Mac."
            phase = .code(saved.peerID)
            snapshot = nil
        } catch {
            if snapshot == nil {
                phase = .offline
                statusLine = saved.remoteHost != nil ? "The Mac at \(saved.remoteHost!) did not answer." : "The Mac did not answer."
            }
        }
    }

    /// Triggers a safe Standard Clean on the connected Mac over the local network or Tailscale/Domain.
    func triggerRemoteClean() async {
        if isDemoMode {
            isCleaning = true
            cleanError = nil
            try? await Task.sleep(for: .seconds(1))
            isCleaning = false
            let demoRes = CompanionCleanResponse(
                status: "success",
                bytesReclaimed: 4_200_000_000,
                formattedBytesReclaimed: "4.2 GB",
                itemsRemoved: 28,
                snapshotCreated: true,
                snapshotName: "com.apple.TimeMachine.2026-10-01-DemoSnapshot.local",
                tier: "standard"
            )
            lastCleanResult = demoRes
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        isCleaning = true
        cleanError = nil
        let defaults = UserDefaults(suiteName: appGroupSuite)
        defaults?.set("Cleaning…", forKey: "clean_status")
        defer { isCleaning = false }
        do {
            let res = try await CompanionConnection.triggerClean(endpoint: endpoint, token: saved.token)
            lastCleanResult = res
            defaults?.set("Cleaned", forKey: "clean_status")
            defaults?.set(Date().timeIntervalSince1970, forKey: "last_clean_date")
            defaults?.set(res.formattedBytesReclaimed, forKey: "last_clean_bytes")
            // Refresh snapshot to reflect reclaimed memory/disk immediately
            await refresh()
        } catch {
            cleanError = "Could not start safe clean. The Mac may be busy or unreachable."
            defaults?.set("Clean failed", forKey: "clean_status")
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: CompanionService.type, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .waiting:
                    self.statusLine = "Allow Local Network for Hog Hunter when this iPhone asks."
                case .failed:
                    self.statusLine = "Hog Hunter could not look for your Mac on this Wi-Fi."
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.unique(results.compactMap(Self.mac(from:)))
            Task { @MainActor in
                guard let self else { return }
                self.didBrowse = true
                self.discovered = found
                self.noteDiscovery()
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func noteDiscovery() {
        if case .code = phase { return }
        if phase == .live, saved != nil, discovered.contains(where: { $0.id == saved?.peerID }) {
            return
        }
        reconcile()
    }

    private func reconcile() {
        if saved == nil {
            phase = discovered.isEmpty ? .looking : .choose
            statusLine = discovered.isEmpty
                ? "Looking for Hog Hunter on this Wi-Fi."
                : "Pick the Mac you want to watch."
            return
        }
        if discovered.contains(where: { $0.id == saved?.peerID }) {
            return
        }
        phase = .offline
        statusLine = "Can't see \(saved?.name ?? "your Mac") on this Wi-Fi."
    }

    private func loadSaved() -> SavedMac? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SavedMac.self, from: data)
    }

    private func persistSaved() {
        guard let saved, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    nonisolated private static func unique(_ macs: [DiscoveredMac]) -> [DiscoveredMac] {
        var seen = Set<String>()
        return macs.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func mac(from result: NWBrowser.Result) -> DiscoveredMac? {
        var name = "Mac"
        if case let .service(serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }
        var peerID = name
        if case let .bonjour(record) = result.metadata {
            if let id = record["id"], !id.isEmpty { peerID = id }
        }
        return DiscoveredMac(id: peerID, name: name, endpoint: result.endpoint)
    }

    private static func fetch(endpoint: NWEndpoint, token: String) async throws -> CompanionSnapshot {
        try await withThrowingTaskGroup(of: CompanionSnapshot.self) { group in
            group.addTask {
                try await CompanionConnection.fetch(endpoint: endpoint, token: token)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw CompanionClientError.timedOut
            }
            guard let value = try await group.next() else {
                throw CompanionClientError.badResponse
            }
            group.cancelAll()
            return value
        }
    }

    static let sample = CompanionSnapshot(
        version: CompanionService.version,
        hostName: "This Mac",
        sampledAt: Date(timeIntervalSince1970: 1_758_000_000),
        hasBaseline: true,
        window: "Now",
        grouping: "Apps",
        cpuScale: "Per Core",
        pulse: CompanionPulse(
            cpuPercent: 37,
            cpuText: "37%",
            cpuCaption: "of all 10 cores",
            cpuSeverity: "calm",
            memoryPercent: 72,
            memoryText: "11.5 of 16 GB",
            memoryCaption: "Memory in use",
            swapText: "1.2 GB swapped",
            pressureText: "Pressure warning",
            pressureSeverity: "elevated"
        ),
        rows: [
            CompanionRow(id: "chrome", name: "Google Chrome", detail: "6 processes", cpuText: "186%", memoryText: "2.4 GB", severity: "elevated", isApp: true, cpuPercent: 186.0, memoryBytes: 2_576_980_377, pid: 1042, canQuit: true),
            CompanionRow(id: "code", name: "Code", detail: "4 processes", cpuText: "92.0%", memoryText: "1.1 GB", severity: "calm", isApp: true, cpuPercent: 92.0, memoryBytes: 1_181_116_006, pid: 2104, canQuit: true),
            CompanionRow(id: "node", name: "node", detail: "pid 4182", cpuText: "310%", memoryText: "640 MB", severity: "hot", isApp: false, cpuPercent: 310.0, memoryBytes: 671_088_640, pid: 4182, canQuit: true),
        ],
        storage: CompanionStorageSummary(
            freeBytes: 120_000_000_000,
            totalBytes: 500_000_000_000,
            usedBytes: 380_000_000_000,
            freeText: "120 GB Free",
            totalText: "500 GB Total",
            usedText: "380 GB Used",
            usedPercent: 76.0,
            standardCleanableBytes: 4_200_000_000,
            standardCleanableText: "4.2 GB Cleanable",
            excludedCategories: ["Trash Bins"],
            excludedPathsCount: 2
        ),
        network: [
            CompanionNetworkRow(
                id: "chrome",
                name: "Google Chrome",
                pid: 1042,
                establishedCount: 18,
                uniqueRemoteHosts: 8,
                sampleRemoteHosts: ["142.250.190.46:443", "151.101.1.69:443", "172.217.16.206:443"]
            ),
            CompanionNetworkRow(
                id: "slack",
                name: "Slack",
                pid: 1420,
                establishedCount: 6,
                uniqueRemoteHosts: 3,
                sampleRemoteHosts: ["54.230.97.10:443", "3.220.12.91:443"]
            )
        ]
    )
}
