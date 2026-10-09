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

enum CompanionClientError: Error, Equatable, LocalizedError {
    case unauthorized
    case badResponse
    case timedOut
    /// The Mac said no, with a reason worth showing (403).
    case forbidden(String)
    /// The Mac is already showing another pairing alert (429).
    case busy
    /// The Mac understood and refused, with a reason worth showing (409 and
    /// other typed refusals).
    case rejected(String)
    /// Too many wrong tries.  The Mac asks the phone to wait (429).
    case throttled(retryAfter: Int)
    /// The Mac's copy of Hog Hunter predates per-phone tokens.
    case tooOld
    /// This connection comes from outside the local network and Tailscale,
    /// where the Mac shows data but accepts no controls and no new pairing.
    case untrustedNetwork

    /// What the person sees.  Without this a thrown error reads as
    /// "The operation couldn't be completed. (HogHunter.CompanionClientError error 1.)"
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The Mac no longer recognizes this iPhone.\u{00A0} Pair it again from the Mac's Settings."
        case .badResponse:
            return "The Mac sent a reply this app could not read.\u{00A0} Update Hog Hunter on both devices."
        case .timedOut:
            return "The Mac did not answer in time.\u{00A0} Check that Hog Hunter is open and the connection is up."
        case .forbidden(let reason), .rejected(let reason):
            return reason
        case .busy:
            return "The Mac is already showing a pairing request."
        case .untrustedNetwork:
            return "Quit, tame, clean, and edit work only on your local network or over Tailscale.\u{00A0} This iPhone can still watch the Mac from here."
        case .tooOld:
            return "This Mac's copy of Hog Hunter is older than this app.\u{00A0} Update it on the Mac."
        case .throttled(let seconds):
            return seconds > 0
                ? "Too many tries.\u{00A0} Wait \(seconds) seconds, then try again."
                : "Too many tries.\u{00A0} Wait a moment, then try again."
        }
    }
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
    /// Set when a control call (exclusions, view, quit, tame) did not go
    /// through, so the dashboard can say so instead of silently doing nothing.
    var controlError: String?
    var showCleanDialogRequested = false
    /// The row a Sample for 3 Seconds is running on, so the row can say so and
    /// a second tap does not start a second sample.
    var samplingRowId: String?
    /// How many settings changes are on their way to the Mac.  A count, not a
    /// flag, so one finishing does not re-enable controls while another is out.
    private(set) var settingsInFlight = 0
    var isApplyingSettings: Bool { settingsInFlight > 0 }
    /// What the Mac said about the last settings change that went through
    /// ("A test message is on its way.").
    var settingsNotice: String?
    /// Why the last settings change did not go through.  Kept apart from
    /// `controlError` because the settings screen is a sheet over the
    /// dashboard, and two alerts on one error cannot both present.
    var settingsError: String?
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
            let credential = try await Self.credential(forCode: token, endpoint: mac.endpoint)
            let next = try await Self.fetch(endpoint: mac.endpoint, token: credential)
            saved = SavedMac(peerID: mac.id, name: mac.name, token: credential)
            persistSaved()
            snapshot = next
            codeError = nil
            phase = .live
        } catch {
            codeError = Self.codeMessage(for: error)
        }
    }

    /// Trades the typed pairing code for this phone's own token, so the Mac
    /// can list it and cut it off alone.  A Mac that predates tokens answers
    /// 404; the code itself then stays the credential, as it always was.
    private static func credential(forCode code: String, endpoint: NWEndpoint) async throws -> String {
        let name = await deviceName()
        do {
            return try await CompanionConnection.enroll(endpoint: endpoint, code: code, deviceName: name)
        } catch CompanionClientError.tooOld {
            return code
        } catch CompanionClientError.untrustedNetwork {
            // Off the local network and Tailscale the Mac will not hand out a
            // token, but it still shows data to the code.  Keep the code; the
            // quiet upgrade finishes once the phone is somewhere trusted.
            return code
        }
    }

    /// What to tell the person when typing a code did not work.
    private static func codeMessage(for error: Error) -> String {
        switch error as? CompanionClientError {
        case .unauthorized?:
            return "That code does not match this Mac."
        case .throttled?, .forbidden?, .rejected?, .tooOld?, .untrustedNetwork?:
            return describe(error)
        default:
            return "The Mac did not answer.\u{00A0} Check that Share With iPhone is on."
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
        case .throttled?, .tooOld?, .rejected?, .untrustedNetwork?: return describe(error)
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
        reconcile()
    }

    /// Quits the app or process in `row`.  The Mac acts on the whole row, so
    /// quitting an app closes all of its processes, each after a live check
    /// that the pid still belongs to the process the Mac showed.
    func quitProcess(row: CompanionRow, force: Bool = false) async -> CompanionQuitResponse {
        let pid = row.pid ?? 0
        if isDemoMode {
            if let index = snapshot?.rows.firstIndex(where: { $0.id == row.id }) {
                snapshot?.rows.remove(at: index)
            }
            return CompanionQuitResponse(
                status: force ? "forced" : "asked",
                pid: pid,
                name: row.name,
                message: "\(force ? "Force quit" : "Quit") command delivered to Mac.",
                error: nil
            )
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            return CompanionQuitResponse(status: "failed", pid: pid, name: row.name, message: nil, error: "Not connected to Mac.")
        }
        do {
            let resp = try await CompanionConnection.triggerQuit(endpoint: endpoint, token: saved.token, pid: pid, rowId: row.id, force: force)
            Task { await refresh() }
            return resp
        } catch {
            return CompanionQuitResponse(status: "failed", pid: pid, name: row.name, message: nil, error: Self.describe(error))
        }
    }

    func tameProcess(row: CompanionRow, action: String = "tame") async -> CompanionTameResponse {
        let pid = row.pid ?? 0
        if isDemoMode {
            if let index = snapshot?.rows.firstIndex(where: { $0.id == row.id }) {
                snapshot?.rows[index].isTamed = (action == "tame")
            }
            return CompanionTameResponse(
                status: "success",
                pid: pid,
                name: row.name,
                isTamed: action == "tame",
                message: action == "tame" ? "Process priority lowered to background QoS." : "Process priority restored to normal.",
                error: nil
            )
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            return CompanionTameResponse(status: "failed", pid: pid, name: row.name, isTamed: false, message: nil, error: "Not connected to Mac.")
        }
        do {
            let resp = try await CompanionConnection.triggerTame(endpoint: endpoint, token: saved.token, pid: pid, rowId: row.id, action: action)
            Task { await refresh() }
            return resp
        } catch {
            return CompanionTameResponse(status: "failed", pid: pid, name: row.name, isTamed: false, message: nil, error: Self.describe(error))
        }
    }

    /// Runs Sample for 3 Seconds on the Mac for `row`.  The report stays on
    /// the Mac; the reply names it and lists the busiest call sites.
    func sampleProcess(row: CompanionRow) async -> CompanionSampleResponse {
        guard samplingRowId == nil else {
            return CompanionSampleResponse(status: "busy", name: row.name, error: "A sample is already running.\u{00A0} Wait for it to finish.")
        }
        samplingRowId = row.id
        defer { samplingRowId = nil }
        if isDemoMode {
            try? await Task.sleep(for: .seconds(1))
            return Self.sampleSampleResponse(name: row.name, rowId: row.pid ?? 0)
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            return CompanionSampleResponse(status: "failed", name: row.name, error: "Not connected to Mac.")
        }
        do {
            return try await CompanionConnection.triggerSample(endpoint: endpoint, token: saved.token, rowId: row.id)
        } catch {
            return CompanionSampleResponse(status: "failed", name: row.name, error: Self.describe(error))
        }
    }

    /// What a finished Sample for 3 Seconds looks like, for demo mode and the
    /// screenshot lane.
    static func sampleSampleResponse(name: String, rowId: Int32) -> CompanionSampleResponse {
        CompanionSampleResponse(
            status: "ok",
            name: name,
            message: "Sampled \(name) for 3 seconds.\u{00A0} The report is on the Mac in Logs/HogHunter.",
            fileName: "\(name)-\(rowId)-20261009-101500.txt",
            bytes: 412_000,
            summary: [
                "__psynch_cvwait  (in libsystem_kernel.dylib)        1840",
                "mach_msg2_trap  (in libsystem_kernel.dylib)        1212",
                "-[NSApplication run]  (in AppKit)        96",
            ]
        )
    }

    /// Sends a settings change to the Mac.  The Mac checks every value; a
    /// refusal lands in `settingsError` and a success in `settingsNotice`.
    func updateSettings(_ update: CompanionSettingsUpdateRequest) async {
        settingsNotice = nil
        settingsError = nil
        if isDemoMode {
            guard var settings = snapshot?.settings else { return }
            if let value = update.refreshInterval { settings.refreshInterval = value }
            if let value = update.alertsEnabled { settings.alertsEnabled = value }
            if let value = update.alertThresholdPercent { settings.alertThresholdPercent = value }
            if let value = update.alertSustainedMinutes { settings.alertSustainedMinutes = value }
            if let url = update.webhookURL {
                settings.webhookConfigured = !url.isEmpty
                settings.webhookHost = url.isEmpty ? nil : URL(string: url)?.host
                if url.isEmpty { settings.webhookStatus = nil }
            }
            if update.testWebhook == true {
                settings.webhookStatus = "Delivered (200) at 10:15:00 AM"
                settingsNotice = "Settings updated.\u{00A0} A test message is on its way."
            }
            snapshot?.settings = settings
            return
        }
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            settingsError = "Not connected to your Mac.\u{00A0} Wait for Hog Hunter to find it, then try again."
            return
        }
        // The webhook address is a secret and this link is not encrypted.  The
        // Mac would refuse a control from outside your network, but it has read
        // the request by then, so the phone does not send it.
        if let url = update.webhookURL, !url.isEmpty, !CompanionPeer.isTrustedEndpoint(endpoint) {
            settingsError = "The webhook address is a secret, so this iPhone sends it only over your local network or Tailscale.\u{00A0} Connect that way, then try again."
            return
        }
        settingsInFlight += 1
        defer { settingsInFlight -= 1 }
        do {
            let res = try await CompanionConnection.triggerSettingsUpdate(endpoint: endpoint, token: saved.token, update: update)
            if res.status == "ok" {
                settingsNotice = res.message
            } else {
                settingsError = res.error ?? "The Mac did not accept that change."
            }
        } catch {
            settingsError = Self.describe(error)
        }
        // The Mac applies the change on its main thread just after it answers.
        try? await Task.sleep(for: .milliseconds(400))
        await refresh()
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
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: token, toggleCategory: id)
            return (res.status == "ok", res.message)
        }
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
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: token, addPath: trimmed)
            return (res.status == "ok", res.message)
        }
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
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerExclusionsUpdate(endpoint: endpoint, token: token, removePath: path)
            return (res.status == "ok", res.message)
        }
    }

    func switchWindow(_ window: String) async {
        if isDemoMode {
            snapshot?.window = window
            return
        }
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: token, window: window)
            return (res.status == "ok", res.message)
        }
    }

    func switchGrouping(_ grouping: String) async {
        if isDemoMode {
            snapshot?.grouping = grouping
            return
        }
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: token, grouping: grouping)
            return (res.status == "ok", res.message)
        }
    }

    func switchCpuScale(_ scale: String) async {
        if isDemoMode {
            snapshot?.cpuScale = scale
            return
        }
        await sendControl { endpoint, token in
            let res = try await CompanionConnection.triggerViewUpdate(endpoint: endpoint, token: token, cpuScale: scale)
            return (res.status == "ok", res.message)
        }
    }

    /// Runs one edit on the Mac and refreshes.  A failure lands in
    /// `controlError` for the dashboard to show, never in a silent catch.
    private func sendControl(_ call: (_ endpoint: NWEndpoint, _ token: String) async throws -> (ok: Bool, message: String?)) async {
        guard let saved, let endpoint = activeEndpoint(for: saved) else {
            controlError = "Not connected to your Mac.\u{00A0} Wait for Hog Hunter to find it, then try again."
            return
        }
        do {
            let outcome = try await call(endpoint, saved.token)
            if !outcome.ok {
                controlError = outcome.message ?? "The Mac did not accept that change."
            }
            await refresh()
        } catch {
            controlError = Self.describe(error)
            await refresh()
        }
    }

    /// A sentence for any error a control call can throw.
    static func describe(_ error: Error) -> String {
        if let known = error as? CompanionClientError, let text = known.errorDescription {
            return text
        }
        if error is CancellationError {
            return "The request was cancelled."
        }
        return "Could not reach the Mac.\u{00A0} Check that Hog Hunter is open and Share With iPhone is on."
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
                token = try await Self.credential(forCode: typed, endpoint: endpoint)
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
            Task { await upgradeToDeviceTokenIfNeeded() }
        } catch CompanionClientError.unauthorized {
            codeError = CompanionToken.isDeviceToken(saved.token)
                ? "This iPhone is no longer paired with the Mac.\u{00A0} Enter the code from Hog Hunter Settings to pair it again."
                : "The code no longer matches.\u{00A0} Enter the code from Hog Hunter Settings on your Mac."
            phase = .code(saved.peerID)
            snapshot = nil
        } catch {
            if snapshot == nil {
                phase = .offline
                statusLine = saved.remoteHost != nil ? "The Mac at \(saved.remoteHost!) did not answer." : "The Mac did not answer."
            }
        }
    }

    private var lastUpgradeAttempt = Date.distantPast
    private var macPredatesTokens = false

    /// A phone paired before per-phone tokens holds the shared code, which can
    /// only read.  Trade it for a token of its own, quietly, so quit, tame,
    /// clean and edit work again without pairing from scratch.  Tried at most
    /// once a minute, and not at all against a Mac that does not know tokens.
    private func upgradeToDeviceTokenIfNeeded() async {
        guard let current = saved,
              !isDemoMode,
              !macPredatesTokens,
              !CompanionToken.isDeviceToken(current.token),
              Date().timeIntervalSince(lastUpgradeAttempt) >= 60,
              let endpoint = activeEndpoint(for: current) else { return }
        lastUpgradeAttempt = Date()
        do {
            let token = try await CompanionConnection.enroll(endpoint: endpoint, code: current.token, deviceName: await Self.deviceName())
            // Pairing may have changed while the Mac answered.
            guard var latest = saved, latest.peerID == current.peerID, latest.token == current.token else { return }
            latest.token = token
            saved = latest
            persistSaved()
        } catch CompanionClientError.tooOld {
            macPredatesTokens = true
        } catch {
            // Wrong code, off the local network, throttled: stay as we are
            // and try again later.
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
        } catch CompanionClientError.rejected(let reason) {
            // The Mac is already cleaning (409).  Its progress is on screen.
            cleanError = reason
            defaults?.set("Clean busy", forKey: "clean_status")
        } catch {
            // The reply can be lost while the Mac keeps cleaning: the phone
            // slept, or the Wi-Fi blinked.  Look before calling it a failure.
            await refresh()
            if snapshot?.cleanProgress?.isCleaning == true {
                cleanError = "Lost the connection while the Mac was cleaning.\u{00A0} It is still running; its progress shows here."
                defaults?.set("Cleaning…", forKey: "clean_status")
            } else {
                cleanError = "Could not finish the clean.\u{00A0} \(Self.describe(error))"
                defaults?.set("Clean failed", forKey: "clean_status")
            }
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
            coreCount: 10,
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
        ],
        // Demo mode shows every control, the way a Mac with all opt-ins on does.
        remoteQuitAllowed: true,
        remoteCleanAllowed: true,
        remoteEditAllowed: true,
        bandwidth: CompanionBandwidth(
            isMeasured: true,
            downBytesPerSecond: 2_411_520,
            upBytesPerSecond: 183_296,
            downText: "2.3 MB/s",
            upText: "179 KB/s",
            nowFootnote: "Last 25 s",
            peakDownBytesPerSecond: 48_234_496,
            peakUpBytesPerSecond: 6_291_456,
            peakDownText: "46.0 MB/s",
            peakUpText: "6.0 MB/s",
            peakFootnote: "Sampled 23h 41m",
            peakHelp: "The fastest sustained rate in the last 24 hours, reached at 2:14 AM."
        ),
        cpuHistory: [22, 24, 31, 28, 35, 42, 57, 61, 48, 39, 36, 33, 38, 44, 52, 66, 71, 58, 49, 41, 37, 35, 34, 38, 36, 35, 37, 39, 38, 37],
        settings: CompanionSettingsSummary(
            refreshInterval: 3,
            alertsEnabled: true,
            alertThresholdPercent: 300,
            alertSustainedMinutes: 5,
            webhookConfigured: true,
            webhookHost: "hooks.example.com",
            webhookStatus: "Delivered (200) at 9:41:07 AM",
            notificationsDenied: false
        )
    )
}
