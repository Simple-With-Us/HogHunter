import Foundation
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

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
    /// The Mac said no, with a reason worth showing (403).
    case forbidden(String)
    /// The Mac is already showing another pairing alert (429).
    case busy
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
    var showForgetConfirm = false
    var remoteHostDraft = ""
    var remotePortDraft = "24240"
    var remoteTokenDraft = ""
    var remoteNameDraft = ""
    var remoteConnectError: String?
    var isConnectingRemote = false
    /// True while the Mac is showing its "Pair this iPhone?" alert.
    var isWaitingForApproval = false
    /// False when this iPhone has no Wi-Fi path, so Bonjour cannot find a
    /// Mac and the app should offer Tailscale or a custom address instead.
    private(set) var isOnWiFi = true
    /// The port Hog Hunter listens on unless the Mac says otherwise.
    static let defaultPort = 24240
    /// How long to wait for the person at the Mac to answer the alert.
    static let approvalTimeout: Duration = .seconds(90)
    private var pathMonitor: NWPathMonitor?

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
        startPathMonitor()
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
        guard case .code = phase else {
            reconcile()
            return
        }
        // A manual host is not in the Bonjour list, so reconcile would return
        // without leaving the pairing sheet.
        if let saved, CompanionReach.keepsManualHost(saved.remoteHost) {
            if snapshot != nil {
                phase = .live
                statusLine = "\(saved.name) (Remote)"
            } else {
                phase = .offline
                statusLine = "The Mac at \(saved.remoteHost ?? "that address") did not answer."
            }
            return
        }
        if saved == nil {
            phase = discovered.isEmpty ? .looking : .choose
            statusLine = discovered.isEmpty
                ? "Looking for Hog Hunter on this Wi-Fi."
                : "Pick the Mac you want to watch."
            return
        }
        reconcile()
        if case .code = phase {
            phase = snapshot == nil ? .offline : .live
        }
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

    /// Asks the Mac on this Wi-Fi to approve the phone instead of typing the
    /// code.  The Mac shows an alert; on Allow it hands the code back.
    func requestApproval() async {
        guard case let .code(peerID) = phase else {
            codeError = "Pick a Mac first."
            return
        }
        guard let mac = discovered.first(where: { $0.id == peerID }) else {
            codeError = "That Mac is no longer on this Wi-Fi.  Keep Hog Hunter open on it, or use Connect by Tailscale or Address."
            return
        }
        codeError = nil
        isWaitingForApproval = true
        defer { isWaitingForApproval = false }
        do {
            let token = try await Self.approve(endpoint: mac.endpoint)
            let next = try await Self.fetch(endpoint: mac.endpoint, token: token)
            saved = SavedMac(peerID: mac.id, name: mac.name, token: token)
            persistSaved()
            snapshot = next
            phase = .live
        } catch {
            codeError = Self.approvalMessage(for: error)
        }
    }

    private static func approve(endpoint: NWEndpoint) async throws -> String {
        let name = await deviceName()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await CompanionConnection.requestPair(endpoint: endpoint, deviceName: name) }
            group.addTask {
                try await Task.sleep(for: approvalTimeout)
                throw CompanionClientError.timedOut
            }
            guard let value = try await group.next() else { throw CompanionClientError.badResponse }
            group.cancelAll()
            return value
        }
    }

    private static func deviceName() async -> String {
        #if canImport(UIKit)
        return await MainActor.run { UIDevice.current.name }
        #else
        return "iPhone"
        #endif
    }

    private static func approvalMessage(for error: Error) -> String {
        switch error as? CompanionClientError {
        case .forbidden(let reason)?: return reason
        case .busy?: return "The Mac is already showing a pairing request.  Answer it there, then try again."
        case .timedOut?: return "No one answered on the Mac.  Try again, or type the code from Hog Hunter Settings."
        default: return "The Mac did not answer.  Check that Hog Hunter is open and Share With iPhone is on."
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.isOnWiFi = wifi }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
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
        phase = .looking
        statusLine = CompanionReach.keepsManualHost(saved?.remoteHost)
            ? "Reconnecting to \(saved?.name ?? "your Mac")."
            : "Looking for Hog Hunter on this Wi-Fi."
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

    func tameProcess(pid: Int32, action: String = "tame") async -> CompanionTameResponse {
        if isDemoMode {
            let targetName = snapshot?.rows.first(where: { $0.pid == pid })?.name ?? "Process"
            if let index = snapshot?.rows.firstIndex(where: { $0.pid == pid }) {
                snapshot?.rows[index].isTamed = (action == "tame")
            }
            return CompanionTameResponse(
                status: "success",
                pid: pid,
                name: targetName,
                isTamed: action == "tame",
                message: action == "tame" ? "Process priority lowered to background QoS." : "Process priority restored to normal.",
                error: nil
            )
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            return CompanionTameResponse(
                status: "failed",
                pid: pid,
                name: "",
                isTamed: false,
                message: nil,
                error: "Not connected to Mac."
            )
        }
        do {
            let resp = try await CompanionConnection.triggerTame(endpoint: endpoint, token: saved.token, pid: pid, action: action)
            Task { await refresh() }
            return resp
        } catch {
            return CompanionTameResponse(
                status: "failed",
                pid: pid,
                name: "",
                isTamed: false,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    func toggleCategoryExclusion(id: String) async {
        if isDemoMode {
            guard var storage = snapshot?.storage else { return }
            var breakdown = storage.categoryBreakdown ?? []
            if let idx = breakdown.firstIndex(where: { $0.id == id }) {
                breakdown[idx].isExcluded.toggle()
                storage.categoryBreakdown = breakdown
                var excluded = storage.excludedCategories ?? []
                let catTitle = breakdown[idx].title
                if breakdown[idx].isExcluded {
                    if !excluded.contains(catTitle) { excluded.append(catTitle) }
                } else {
                    excluded.removeAll { $0 == catTitle }
                }
                storage.excludedCategories = excluded
                snapshot?.storage = storage
            }
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: saved.token, toggleCategory: id)
            await refresh()
        } catch {}
    }

    func addExcludedPath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isDemoMode {
            guard var storage = snapshot?.storage else { return }
            var paths = storage.excludedPaths ?? []
            if !paths.contains(trimmed) {
                paths.append(trimmed)
                storage.excludedPaths = paths
                storage.excludedPathsCount = paths.count
                snapshot?.storage = storage
            }
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: saved.token, addPath: trimmed)
            await refresh()
        } catch {}
    }

    func removeExcludedPath(_ path: String) async {
        if isDemoMode {
            guard var storage = snapshot?.storage else { return }
            var paths = storage.excludedPaths ?? []
            paths.removeAll { $0 == path }
            storage.excludedPaths = paths
            storage.excludedPathsCount = paths.count
            snapshot?.storage = storage
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: saved.token, removePath: path)
            await refresh()
        } catch {}
    }

    func switchWindow(_ window: String) async {
        if isDemoMode {
            snapshot?.window = window
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: saved.token, window: window)
            await refresh()
        } catch {}
    }

    func switchGrouping(_ grouping: String) async {
        if isDemoMode {
            snapshot?.grouping = grouping
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: saved.token, grouping: grouping)
            await refresh()
        } catch {}
    }

    func switchCpuScale(_ scale: String) async {
        if isDemoMode {
            snapshot?.cpuScale = scale
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        do {
            _ = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: saved.token, cpuScale: scale)
            await refresh()
        } catch {}
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

    private var remoteConnectTask: Task<Void, Never>?

    func startRemoteConnect() {
        remoteConnectTask?.cancel()
        remoteConnectTask = Task { [weak self] in
            await self?.connectRemote()
        }
    }

    func cancelRemoteConnect() {
        remoteConnectTask?.cancel()
        remoteConnectTask = nil
        isConnectingRemote = false
        isWaitingForApproval = false
    }

    func connectRemote() async {
        let host = remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            remoteConnectError = "Enter a Tailscale MagicDNS name, IP address, or domain."
            return
        }
        let portNum = Int(remotePortDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Self.defaultPort
        let typed = remoteTokenDraft.uppercased().filter { CompanionToken.alphabet.contains($0) }
        guard typed.isEmpty || typed.count >= 8 else {
            remoteConnectError = "The Pairing Code is 8 characters.  Leave it blank to approve on the Mac instead."
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portNum)) else {
            remoteConnectError = "Invalid port number."
            return
        }

        isConnectingRemote = true
        remoteConnectError = nil
        let previous = remoteConnectTask
        defer {
            isConnectingRemote = false
            //  Only clear the handle if it is still the one this run installed.
            //  A cancelled run that unwinds late must not nil out the live task
            //  a later attempt is holding.
            if remoteConnectTask == previous { remoteConnectTask = nil }
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        do {
            let token: String
            if typed.isEmpty {
                isWaitingForApproval = true
                defer { isWaitingForApproval = false }
                token = try await Self.approve(endpoint: endpoint)
            } else {
                token = typed
            }
            guard !Task.isCancelled else { return }
            let fetched = try await Self.fetch(endpoint: endpoint, token: token)
            guard !Task.isCancelled else { return }
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
            remoteConnectError = "Pairing Code does not match this Mac."
        } catch let error as CompanionClientError where error != .badResponse {
            remoteConnectError = Self.approvalMessage(for: error)
        } catch {
            guard !Task.isCancelled else { return }
            remoteConnectError = "Could not reach \(host) on port \(portNum).  Check that Hog Hunter is open on the Mac, Share With iPhone is on, and Tailscale is connected on both devices."
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
            snapshot?.cleanProgress = CompanionCleanProgress(
                isCleaning: true,
                phase: "snapshot",
                progress: 0.15,
                statusText: "Creating APFS safety snapshot…",
                currentItem: nil,
                itemsCleaned: 0,
                totalItems: 28,
                bytesReclaimed: 0,
                formattedBytesReclaimed: "0 B",
                snapshotName: nil,
                error: nil
            )
            try? await Task.sleep(for: .milliseconds(800))
            snapshot?.cleanProgress = CompanionCleanProgress(
                isCleaning: true,
                phase: "cleaning",
                progress: 0.55,
                statusText: "Cleaning User Caches…",
                currentItem: "com.apple.Safari",
                itemsCleaned: 15,
                totalItems: 28,
                bytesReclaimed: 2_100_000_000,
                formattedBytesReclaimed: "2.1 GB",
                snapshotName: nil,
                error: nil
            )
            try? await Task.sleep(for: .milliseconds(800))
            let demoRes = CompanionCleanResponse(
                status: "success",
                bytesReclaimed: 4_200_000_000,
                formattedBytesReclaimed: "4.2 GB",
                itemsRemoved: 28,
                snapshotCreated: true,
                snapshotName: "com.apple.TimeMachine.2026-10-01-DemoSnapshot.local",
                tier: "standard"
            )
            snapshot?.cleanProgress = CompanionCleanProgress(
                isCleaning: false,
                phase: "completed",
                progress: 1.0,
                statusText: "Clean complete: Reclaimed 4.2 GB",
                currentItem: nil,
                itemsCleaned: 28,
                totalItems: 28,
                bytesReclaimed: 4_200_000_000,
                formattedBytesReclaimed: "4.2 GB",
                snapshotName: "com.apple.TimeMachine.2026-10-01-DemoSnapshot.local",
                error: nil
            )
            lastCleanResult = demoRes
            isCleaning = false
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else { return }
        isCleaning = true
        cleanError = nil
        let defaults = UserDefaults(suiteName: appGroupSuite)
        defaults?.set("Cleaning…", forKey: "clean_status")

        // Start high-frequency polling during clean execution so progress updates are relayed smoothly
        let pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                await self?.refresh()
            }
        }

        defer {
            pollingTask.cancel()
            isCleaning = false
        }

        do {
            let res = try await CompanionConnection.triggerClean(endpoint: endpoint, token: saved.token)
            lastCleanResult = res
            defaults?.set("Cleaned", forKey: "clean_status")
            defaults?.set(Date().timeIntervalSince1970, forKey: "last_clean_date")
            defaults?.set(res.formattedBytesReclaimed, forKey: "last_clean_bytes")
            // Final refresh to ensure completed clean state is captured
            await refresh()
        } catch CompanionClientError.forbidden(let reason) {
            cleanError = reason
            defaults?.set("Clean not allowed", forKey: "clean_status")
        } catch {
            cleanError = "Could not start safe clean.  The Mac may be busy or unreachable."
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
        if CompanionReach.keepsManualHost(saved?.remoteHost) { return }
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
        if CompanionReach.keepsManualHost(saved?.remoteHost) { return }
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
            pressureSeverity: "elevated",
            thermalState: "fair",
            batteryPercent: 88,
            isCharging: true,
            powerSource: "AC"
        ),
        rows: [
            CompanionRow(id: "chrome", name: "Google Chrome", detail: "6 processes", cpuText: "186%", memoryText: "2.4 GB", severity: "elevated", isApp: true, cpuPercent: 186.0, memoryBytes: 2_576_980_377, pid: 1042, canQuit: true, isTamed: false, isSleepBlocker: true, canTame: true),
            CompanionRow(id: "code", name: "Code", detail: "4 processes", cpuText: "92.0%", memoryText: "1.1 GB", severity: "calm", isApp: true, cpuPercent: 92.0, memoryBytes: 1_181_116_006, pid: 2104, canQuit: true, isTamed: false, isSleepBlocker: false, canTame: true),
            CompanionRow(id: "node", name: "node", detail: "pid 4182", cpuText: "310%", memoryText: "640 MB", severity: "hot", isApp: false, cpuPercent: 310.0, memoryBytes: 671_088_640, pid: 4182, canQuit: true, isTamed: true, isSleepBlocker: false, canTame: true),
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
            excludedPathsCount: 2,
            categoryBreakdown: [
                CompanionStorageCategorySummary(id: "userCaches", title: "User Caches", description: "Application cache directories that can be safely rebuilt.", icon: "arrow.triangle.2.circlepath", isExcluded: false, isExtremeOnly: false),
                CompanionStorageCategorySummary(id: "logsAndDiagnostics", title: "Logs & Diagnostics", description: "Old log files, diagnostic reports, and crash dumps.", icon: "doc.text.magnifyingglass", isExcluded: false, isExtremeOnly: false),
                CompanionStorageCategorySummary(id: "trash", title: "Trash Bins", description: "Items sitting in the macOS Trash bin.", icon: "trash", isExcluded: true, isExtremeOnly: false),
                CompanionStorageCategorySummary(id: "developer", title: "Developer Junk", description: "Xcode DerivedData, Archives, iOS DeviceSupport, and package manager caches.", icon: "hammer", isExcluded: false, isExtremeOnly: false),
                CompanionStorageCategorySummary(id: "orphanedData", title: "Orphaned App Leftovers", description: "Support folders remaining from applications no longer installed.", icon: "app.dashed", isExcluded: false, isExtremeOnly: true),
                CompanionStorageCategorySummary(id: "aiArtifacts", title: "AI & Agent Junk", description: "Inactive AI agent session transcripts (>7 days) and temporary update downloads.", icon: "sparkles", isExcluded: false, isExtremeOnly: true),
                CompanionStorageCategorySummary(id: "localAIModels", title: "Local AI & LLM Models", description: "Downloaded LLM and model weights (.gguf, .safetensors, .bin) from Ollama, Hugging Face, LM Studio, and Whisper.", icon: "brain.head.profile", isExcluded: false, isExtremeOnly: true),
                CompanionStorageCategorySummary(id: "largeAndOldFiles", title: "Large & Old Files", description: "Files over 100 MB, or over 20 MB untouched for 6+ months.", icon: "clock.arrow.circlepath", isExcluded: false, isExtremeOnly: true)
            ],
            excludedPaths: [
                "/Users/jay/Code/HogHunter",
                "/Users/jay/Documents/CriticalArchive"
            ]
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
