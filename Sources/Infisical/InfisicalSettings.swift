import AppKit
import Foundation
import LocalAuthentication
import Security

/// Infisical as the sole source of truth for Hog Hunter's app-level settings.
///
/// What this is
/// -------------
/// The fleet-wide Infisical SOT contract (see INFISICAL.md): secrets, env
/// config, and tunable settings knobs live in the app's Infisical project.
/// On launch the app fetches its full settings set into an in-memory cache;
/// every runtime read comes from that cache -- a per-request Infisical fetch
/// is the one forbidden pattern.  The cache refreshes on an interval and
/// whenever the app becomes active; a failed refresh keeps serving the
/// last-known-good values.  Admin saves write through to Infisical first.
///
/// Who owns the Infisical read
/// ----------------------------
/// Hog Hunter has no backend.  The Mac app IS the server for the iPhone
/// companion, and the local user IS the admin (the canonical pattern's
/// single-user case), so the Mac app owns the Infisical read.  A
/// universal-auth client secret is never embedded in the binary: the admin
/// enters it once in Settings > Advanced and it lives in the Keychain.  The
/// iOS companion never talks to Infisical; it receives the effective
/// settings through the Mac's companion snapshot channel.
///
/// The two types
/// -------------
/// `InfisicalStore` is the thread-safe in-memory cache.  It is the ONLY
/// thing runtime code reads (CleanPressure, CleanRegimen, Alerts), so those
/// call sites stay nonisolated and can never accidentally await a network
/// call in a hot path.  `InfisicalSettings` is the @MainActor owner of the
/// network: bootstrap at launch, timer + become-active refresh, write-through
/// on admin save, and the @Published state the Advanced settings tab binds to.

// MARK: - Key inventory

/// Every app-level setting that lives in Infisical.  Per-user display and
/// consent choices (appearance, grouping, sort, alertsEnabled, shareWithIPhone,
/// companion pairing identity, cleaner exclusions) stay in UserDefaults and
/// are deliberately absent here.  The full inventory, including defaults and
/// the boundary, is documented in INFISICAL.md.
enum InfisicalKey {
    static let refreshInterval = "hoghunter.refreshInterval"
    static let alertThresholdPercent = "hoghunter.alertThresholdPercent"
    static let alertSustainedMinutes = "hoghunter.alertSustainedMinutes"
    static let alertCooldownMinutes = "hoghunter.alertCooldownMinutes"
    /// Secret.  Documented as "to be filled by admin"; never invent a value.
    static let alertWebhookURL = "hoghunter.alertWebhookURL"
    static let reclaimCriticalFreeGb = "hoghunter.reclaim.criticalFreeGb"
    static let reclaimAcuteFreeGb = "hoghunter.reclaim.acuteFreeGb"
    static let reclaimHealthyFreeGb = "hoghunter.reclaim.healthyFreeGb"
    static let reclaimCpuIdleFloorPercent = "hoghunter.reclaim.cpuIdleFloorPercent"
    static let reclaimSwapUsedPct = "hoghunter.reclaim.swapUsedPct"
    static let reclaimLoad1Threshold = "hoghunter.reclaim.load1Threshold"
    static let regimenIntervalHours = "hoghunter.regimen.intervalHours"
    static let regimenTargetsPerChunk = "hoghunter.regimen.targetsPerChunk"
    static let regimenChunkPauseSeconds = "hoghunter.regimen.chunkPauseSeconds"
    static let regimenPressuredTargetsPerChunk = "hoghunter.regimen.pressuredTargetsPerChunk"
    static let regimenPressuredChunkPauseSeconds = "hoghunter.regimen.pressuredChunkPauseSeconds"
    static let regimenExpensiveTierFreeGb = "hoghunter.regimen.expensiveTierFreeGb"
    static let settingsRefreshMinutes = "hoghunter.settingsRefreshMinutes"

    // Maintain step toggles and knobs
    static let maintainStepPrefix = "hoghunter.maintain.step."
    static let maintainStepShutdownSimulators = "hoghunter.maintain.step.shutdown_simulators"
    static let maintainStepXcodeDerivedData = "hoghunter.maintain.step.xcode_derived_data"
    static let maintainStepXcodeDeviceSupport = "hoghunter.maintain.step.xcode_device_support"
    static let maintainStepCoreSimulatorCaches = "hoghunter.maintain.step.core_simulator_caches"
    static let maintainStepCleanmymacCli = "hoghunter.maintain.step.cleanmymac_cli"
    static let maintainStepCoolifyRemote = "hoghunter.maintain.step.coolify_remote"
    static let maintainStepJanitorWorktreeRetire = "hoghunter.maintain.step.janitor_worktree_retire"
    static let maintainStepJanitorCacheReclaim = "hoghunter.maintain.step.janitor_cache_reclaim"
    static let maintainIntervalWatchSec = "hoghunter.maintain.interval.watchSec"
    static let maintainIntervalJanitorSec = "hoghunter.maintain.interval.janitorSec"
    static let maintainIntervalFullSec = "hoghunter.maintain.interval.fullSec"
    static let maintainHistoryMaxRuns = "hoghunter.maintain.historyMaxRuns"
    static let maintainCleanBudgetSec = "hoghunter.maintain.cleanBudgetSec"
    static let maintainCoolifySshHost = "hoghunter.maintain.coolifySshHost"
    static let maintainJanitorMaxLoadHard = "hoghunter.maintain.janitor.maxLoadHard"
    static let maintainJanitorLowFreeGib = "hoghunter.maintain.janitor.lowFreeGib"
    static let maintainJanitorRetireMinDays = "hoghunter.maintain.janitor.retireMinDays"
    static let maintainWatchDiskFreeWarnGb = "hoghunter.maintain.watch.diskFreeWarnGb"
    static let maintainWatchSwapUsedPct = "hoghunter.maintain.watch.swapUsedPct"

    /// Every non-secret key, for the Advanced tab's "push current values" seed.
    static let allNonSecret: [String] = [
        refreshInterval, alertThresholdPercent, alertSustainedMinutes, alertCooldownMinutes,
        reclaimCriticalFreeGb, reclaimAcuteFreeGb, reclaimHealthyFreeGb,
        reclaimCpuIdleFloorPercent, reclaimSwapUsedPct, reclaimLoad1Threshold,
        regimenIntervalHours, regimenTargetsPerChunk, regimenChunkPauseSeconds,
        regimenPressuredTargetsPerChunk, regimenPressuredChunkPauseSeconds,
        regimenExpensiveTierFreeGb, settingsRefreshMinutes,
        maintainStepShutdownSimulators, maintainStepXcodeDerivedData,
        maintainStepXcodeDeviceSupport, maintainStepCoreSimulatorCaches,
        maintainStepCleanmymacCli, maintainStepCoolifyRemote,
        maintainStepJanitorWorktreeRetire, maintainStepJanitorCacheReclaim,
        maintainIntervalWatchSec, maintainIntervalJanitorSec, maintainIntervalFullSec,
        maintainHistoryMaxRuns, maintainCleanBudgetSec, maintainCoolifySshHost,
        maintainJanitorMaxLoadHard, maintainJanitorLowFreeGib,
        maintainJanitorRetireMinDays,
        maintainWatchDiskFreeWarnGb, maintainWatchSwapUsedPct,
    ]
}

/// Built-in defaults for every migrated key.  These are the values the repo
/// shipped with; they are also seeded into the Infisical project's prod
/// environment, so a configured app and an unconfigured app agree until an
/// admin changes something.
enum InfisicalDefaults {
    static let values: [String: String] = [
        InfisicalKey.refreshInterval: "5",
        InfisicalKey.alertThresholdPercent: "300",
        InfisicalKey.alertSustainedMinutes: "5",
        InfisicalKey.alertCooldownMinutes: "30",
        InfisicalKey.reclaimCriticalFreeGb: "25",
        InfisicalKey.reclaimAcuteFreeGb: "40",
        InfisicalKey.reclaimHealthyFreeGb: "80",
        InfisicalKey.reclaimCpuIdleFloorPercent: "12",
        InfisicalKey.reclaimSwapUsedPct: "90",
        InfisicalKey.reclaimLoad1Threshold: "40",
        InfisicalKey.regimenIntervalHours: "24",
        InfisicalKey.regimenTargetsPerChunk: "3",
        InfisicalKey.regimenChunkPauseSeconds: "5",
        InfisicalKey.regimenPressuredTargetsPerChunk: "2",
        InfisicalKey.regimenPressuredChunkPauseSeconds: "10",
        InfisicalKey.regimenExpensiveTierFreeGb: "40",
        InfisicalKey.settingsRefreshMinutes: "5",
        InfisicalKey.maintainStepShutdownSimulators: "true",
        InfisicalKey.maintainStepXcodeDerivedData: "true",
        InfisicalKey.maintainStepXcodeDeviceSupport: "false",
        InfisicalKey.maintainStepCoreSimulatorCaches: "true",
        InfisicalKey.maintainStepCleanmymacCli: "false",
        InfisicalKey.maintainStepCoolifyRemote: "false",
        InfisicalKey.maintainStepJanitorWorktreeRetire: "true",
        InfisicalKey.maintainStepJanitorCacheReclaim: "true",
        InfisicalKey.maintainIntervalWatchSec: "300",
        InfisicalKey.maintainIntervalJanitorSec: "1800",
        InfisicalKey.maintainIntervalFullSec: "14400",
        InfisicalKey.maintainHistoryMaxRuns: "500",
        InfisicalKey.maintainCleanBudgetSec: "600",
        InfisicalKey.maintainCoolifySshHost: "",
        InfisicalKey.maintainJanitorMaxLoadHard: "250",
        InfisicalKey.maintainJanitorLowFreeGib: "80",
        InfisicalKey.maintainJanitorRetireMinDays: "7",
        InfisicalKey.maintainWatchDiskFreeWarnGb: "25",
        InfisicalKey.maintainWatchSwapUsedPct: "90",
    ]
}

// MARK: - Errors

enum InfisicalError: Error, CustomStringConvertible {
    case transport(Error)
    case httpStatus(Int, String)
    case decoding(String)
    case notConfigured
    case invalidConfiguration
    case configurationChanged
    case saveInProgress
    case invalidScope
    case readOnly
    case ambiguousKey
    case credentialStorage

    var description: String {
        switch self {
        case .transport: return "Infisical network request failed"
        case .httpStatus(let code, _): return "Infisical request failed (HTTP \(code))"
        case .decoding(let what): return "could not decode \(what)"
        case .notConfigured: return "Infisical is not configured (no credential in Keychain)"
        case .invalidConfiguration: return "Enter a valid Project ID, folder, and credentials for the selected authentication mode"
        case .configurationChanged: return "The Infisical connection changed; try again"
        case .saveInProgress: return "An Infisical connection save is already in progress"
        case .invalidScope: return "Service token metadata must match its project and one exact prod folder with the selected permissions"
        case .readOnly: return "No verified write token is configured for this settings folder"
        case .ambiguousKey: return "Settings keys overlap across folders; choose non-overlapping read routes"
        case .credentialStorage: return "Could not save the Infisical credential securely in Keychain"
        }
    }
}

// MARK: - Universal-auth credential

enum InfisicalAuthMode: String, Codable, CaseIterable, Identifiable {
    case machineIdentity
    case serviceTokens
    var id: String { rawValue }
    var title: String { self == .machineIdentity ? "Machine Identity" : "Service Tokens" }
}

/// Secrets remain inside the Mac's Keychain record, never UserDefaults or the companion snapshot.
struct InfisicalServiceToken: Codable, Identifiable {
    var id = UUID()
    var label = ""
    var projectId = ""
    var secretPath = "/"
    var token = ""
    var reads = true
    var writes = false
}

struct InfisicalCredential: Codable {
    var clientId: String
    var clientSecret: String
    /// Older records without this field remain unconfigured until explicitly saved.
    var projectId: String? = nil
    var mode: InfisicalAuthMode? = nil
    var secretPath: String? = nil
    var serviceTokens: [InfisicalServiceToken]? = nil

    /// A mode-less inherited record is an editor draft, never a runtime login.
    var isOperational: Bool { mode != nil && isComplete }
    var effectiveMode: InfisicalAuthMode { mode ?? .machineIdentity }
    var effectiveProjectId: String { (projectId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var effectivePath: String { secretPath ?? "/" }
    var cacheTargetId: String {
        if effectiveMode == .machineIdentity && effectivePath == "/" { return effectiveProjectId }
        let folders = effectiveMode == .machineIdentity ? [effectivePath] : activeTokens.filter(\.reads).map(\.secretPath).sorted()
        return effectiveProjectId + "|" + effectiveMode.rawValue + "|" + folders.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    var activeTokens: [InfisicalServiceToken] {
        (serviceTokens ?? []).filter { $0.projectId.lowercased() == effectiveProjectId }
    }
    static func validPath(_ path: String) -> Bool {
        path == "/" || (path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("//")
            && !path.contains("*") && !path.contains("?") && !path.contains("\\")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }))
    }
    var isComplete: Bool {
        guard UUID(uuidString: effectiveProjectId) != nil, Self.validPath(effectivePath) else { return false }
        switch effectiveMode {
        case .machineIdentity:
            return !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .serviceTokens:
            let entries = serviceTokens ?? []
            return !entries.isEmpty && activeTokens.contains(where: \.reads) && entries.allSatisfy {
                UUID(uuidString: $0.projectId) != nil && Self.validPath($0.secretPath)
                    && !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.reads || $0.writes)
            }
        }
    }
}

struct InfisicalTokenMetadata {
    struct Scope { var environment: String; var secretPath: String }
    var projectId: String
    var scopes: [Scope]
    var permissions: Set<String>

    /// Legacy bulk reads use token scopes rather than the query path.  Require one
    /// exact scope so a successful HTTP response cannot masquerade as another folder.
    func validates(_ entry: InfisicalServiceToken, environment: String) -> Bool {
        projectId.lowercased() == entry.projectId.lowercased() && scopes.count == 1
            && scopes[0].environment == environment && scopes[0].secretPath == entry.secretPath
            && (!entry.reads || permissions.contains("read"))
            && (!entry.writes || permissions.contains("write"))
    }
}

/// Nonsecret migration marker, separate from credential storage so a missing
/// Keychain item can never redisplay retired legacy machine-identity drafts.
struct InfisicalLegacyCredentialMigration {
    var isRetired: () -> Bool
    var retire: () -> Void

    static var persistent: Self { persistence(in: .standard) }

    static func persistence(in defaults: UserDefaults) -> Self {
        let key = "hoghunter.infisical.legacyFileCredentialRetired"
        return Self(isRetired: { defaults.bool(forKey: key) }, retire: {
            defaults.set(true, forKey: key)
            defaults.synchronize()
        })
    }

    /// Tests inject their own migration state; the default test host never
    /// mutates the installed app's persisted retirement state.
    static var inert: Self { Self(isRetired: { false }, retire: {}) }
}

/// One Keychain lookup.  `terminal` is true only when the Keychain answered:
/// the item was read, or it is definitively absent.  A locked Keychain or a
/// suppressed auth prompt is not terminal and stays retryable.
struct KeychainCredentialRead {
    var credential: InfisicalCredential?
    var terminal: Bool
    /// Only errSecItemNotFound permits looking for a file draft in the editor.
    var absent = false
}

protocol InfisicalServing {
    func login(clientId: String, clientSecret: String) async throws -> String
    func tokenMetadata(token: String) async throws -> InfisicalTokenMetadata
    func fetchSecrets(accessToken: String, environment: String, projectId: String, secretPath: String) async throws -> [String: String]
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String, secretPath: String) async throws
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String]
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws
}

extension InfisicalServing {
    func tokenMetadata(token: String) async throws -> InfisicalTokenMetadata { throw InfisicalError.invalidScope }
    func fetchSecrets(accessToken: String, environment: String, projectId: String, secretPath: String) async throws -> [String: String] {
        guard secretPath == "/" else { throw InfisicalError.invalidScope }
        return try await fetchSecrets(accessToken: accessToken, environment: environment, projectId: projectId)
    }
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String, secretPath: String) async throws {
        guard secretPath == "/" else { throw InfisicalError.invalidScope }
        try await upsertSecret(accessToken: accessToken, environment: environment, key: key, value: value, projectId: projectId)
    }
}

// MARK: - REST client

/// Thin wrapper over the Infisical REST API: universal-auth login, then
/// /api/v3/secrets/raw for reads and /api/v3/secrets (PATCH) for
/// write-through.  The URLSession is injectable so tests can stub the
/// network without touching the real service.
final class InfisicalClient: InfisicalServing {
    static let baseURL = URL(string: "https://app.infisical.com")!

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = InfisicalClient.baseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Universal-auth login.  Returns a short-lived access token.
    func login(clientId: String, clientSecret: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/v1/auth/universal-auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "clientSecret": clientSecret,
        ])
        let (data, response) = try await perform(request)
        try check(response, data: data)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["accessToken"] as? String, !token.isEmpty
        else {
            throw InfisicalError.decoding("universal-auth login response")
        }
        return token
    }

    func tokenMetadata(token: String) async throws -> InfisicalTokenMetadata {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v2/service-token"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try check(response, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = (json["projectId"] ?? json["workspace"]) as? String,
              let scopes = json["scopes"] as? [[String: String]],
              let permissions = json["permissions"] as? [String] else { throw InfisicalError.invalidScope }
        let parsed = scopes.compactMap { scope -> InfisicalTokenMetadata.Scope? in
            guard let environment = scope["environment"], let path = scope["secretPath"] else { return nil }
            return .init(environment: environment, secretPath: path)
        }
        guard parsed.count == scopes.count else { throw InfisicalError.invalidScope }
        if let workspace = json["workspace"] as? String, workspace.lowercased() != project.lowercased() { throw InfisicalError.invalidScope }
        return .init(projectId: project, scopes: parsed, permissions: Set(permissions))
    }

    /// Full settings set for the environment, as key -> value.
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        try await fetchSecrets(accessToken: accessToken, environment: environment, projectId: projectId, secretPath: "/")
    }

    func fetchSecrets(accessToken: String, environment: String, projectId: String, secretPath: String) async throws -> [String: String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v3/secrets/raw"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "workspaceId", value: projectId),
            URLQueryItem(name: "environment", value: environment),
            URLQueryItem(name: "secretPath", value: secretPath),
            URLQueryItem(name: "include_imports", value: "false"),
            URLQueryItem(name: "recursive", value: "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try check(response, data: data)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let secrets = json["secrets"] as? [[String: Any]]
        else {
            throw InfisicalError.decoding("secrets/raw response")
        }
        var out: [String: String] = [:]
        for secret in secrets {
            if let key = secret["secretKey"] as? String,
               let value = secret["secretValue"] as? String {
                out[key] = value
            }
        }
        return out
    }

    /// Write-through: create-or-update a single secret.  The secret name goes
    /// in the path (PATCH /api/v3/secrets/raw/{name}), falling back to POST
    /// with `type: "shared"` on a 404 if the secret does not exist yet.
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        try await upsertSecret(accessToken: accessToken, environment: environment, key: key, value: value, projectId: projectId, secretPath: "/")
    }

    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String, secretPath: String) async throws {
        var url = baseURL.appendingPathComponent("/api/v3/secrets/raw")
        url.appendPathComponent(key)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "workspaceId": projectId,
            "environment": environment,
            "secretPath": secretPath,
            "secretValue": value,
        ])
        let (data, response) = try await perform(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            var postRequest = URLRequest(url: url)
            postRequest.httpMethod = "POST"
            postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            postRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            postRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "workspaceId": projectId,
                "environment": environment,
                "secretPath": secretPath,
                "secretValue": value,
                "type": "shared",
            ])
            let (postData, postResponse) = try await perform(postRequest)
            try check(postResponse, data: postData)
            return
        }
        try check(response, data: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw InfisicalError.transport(error)
        }
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw InfisicalError.decoding("HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Server error bodies can echo credentials or secret values.
            throw InfisicalError.httpStatus(http.statusCode, "")
        }
    }
}

// MARK: - In-memory cache (the only thing runtime code reads)

/// Thread-safe in-memory settings cache.  Populated once at launch and
/// refreshed in the background by `InfisicalSettings`; every runtime read is
/// a dictionary lookup -- zero network calls after init, by construction.
/// Deliberately not MainActor-isolated so hot paths (CleanPressure,
/// CleanRegimen, Alerts) can read it without an actor hop.
final class InfisicalStore: @unchecked Sendable {
    static let shared = InfisicalStore()

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var projectId: String?

    /// nil means bootstrap has not resolved a target; "local" means explicitly cleared.
    static let localProjectId = "local"

    var snapshot: (projectId: String?, values: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        return (projectId, values)
    }

    func selectProject(_ projectId: String) {
        lock.lock(); defer { lock.unlock() }
        if self.projectId != projectId { values = [:] }
        self.projectId = projectId
    }

    func replace(_ values: [String: String], projectId: String) {
        lock.lock(); defer { lock.unlock() }
        self.projectId = projectId
        self.values = values
    }

    init(initial: [String: String] = [:]) {
        self.values = initial
    }

    func setAll(_ new: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        values = new
    }

    func set(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func double(for key: String) -> Double? {
        guard let raw = string(for: key) else { return nil }
        return Double(raw)
    }

    func int(for key: String) -> Int? {
        guard let raw = string(for: key) else { return nil }
        return Int(raw)
    }

    func bool(for key: String) -> Bool? {
        guard let raw = string(for: key)?.lowercased() else { return nil }
        switch raw {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }
}

// MARK: - Settings owner

extension Notification.Name {
    /// Posted on the main thread after a successful refresh.  HogStore
    /// observes it to apply Infisical values over its @Published settings.
    static let infisicalSettingsDidRefresh =
        Notification.Name("hoghunter.infisicalSettingsDidRefresh")
}

/// Owns the Infisical relationship: bootstrap at launch, background refresh,
/// and write-through on admin save.  The local user is the admin; the
/// universal-auth credential is entered once in Settings > Advanced and kept
/// in the Keychain -- never in the binary, never in UserDefaults.
@MainActor
final class InfisicalSettings: ObservableObject {
    static let shared = InfisicalSettings()

    /// The app has a single deployment (this Mac), so it reads the prod
    /// environment, and only prod.  The dev and staging environments are
    /// retired (owner, 2026-10-10); this constant is the guard -- nothing in
    /// the app, the Keychain record, or the Settings pane can select another
    /// environment, and a test pins the value.  See INFISICAL.md.
    static let environment = "prod"

    /// The Settings > Advanced note under the credential fields.  Built from
    /// `environment` so the pane can never name a different environment than
    /// the one the app reads.
    static var credentialNotice: String {
        "Uses the \(environment) environment.\u{00A0} The connection is checked before replacing your saved setup."
    }

    @Published private(set) var isConfigured = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var projectId = ""
    @Published private(set) var authMode: InfisicalAuthMode = .machineIdentity
    private var keyPaths: [String: String] = [:]
    private var hasLoadedRoutes = false

    @Published private(set) var hasCredentialDraft = false

    /// Only the editor may inspect inherited credentials, without authenticating.
    /// Operational paths never invoke the file reader or promote these drafts.
    var editingCredential: InfisicalCredential? {
        guard !credentialWasCleared else { return nil }
        // A prior terminal miss is cached for background work only.  Recheck
        // silently before the editor may read a file draft, since Keychain
        // availability or presence may have changed since bootstrap.
        if inMemoryCredential == nil, credentialProvider == nil { keychainReadAttempted = false }
        if let current = credential() { hasCredentialDraft = false; return current }
        guard let read = lastKeychainRead, read.terminal else { return nil }
        if let inherited = read.credential {
            hasCredentialDraft = true
            return inherited
        }
        guard read.absent, !legacyMigration.isRetired(), let draft = legacyDraftReader(),
              draft.effectiveMode == .machineIdentity else { return nil }
        hasCredentialDraft = true
        return draft
    }

    private let client: InfisicalServing
    private let store: InfisicalStore
    private let credentialWriter: (InfisicalCredential) throws -> Void
    private let credentialRemover: () throws -> Void
    private let legacyMigration: InfisicalLegacyCredentialMigration
    private var generation = UUID()
    private var activeSave: UUID?

    /// Capture before scheduling work, so an old UI edit cannot target a newer connection.
    var connectionGeneration: UUID { generation }
    var snapshot: (projectId: String?, values: [String: String]) { store.snapshot }
    private var credentialWasCleared = false
    /// Injectable for tests; nil means "read the Keychain".
    var credentialProvider: (() -> InfisicalCredential?)?
    /// Injectable for tests.  Production reads the Keychain with
    /// authentication UI suppressed, so a retry cannot raise a prompt.
    var keychainReader: @MainActor () -> KeychainCredentialRead
    /// Editor-only, injectable legacy file reader; never called by bootstrap or refresh.
    private let legacyDraftReader: @MainActor () -> InfisicalCredential?
    private var lastKeychainRead: KeychainCredentialRead?
    private var timer: Timer?
    private var bootstrapped = false
    private var becomeActiveObserver: NSObjectProtocol?

    init(
        client: InfisicalServing = InfisicalClient(),
        store: InfisicalStore = .shared,
        credentialProvider: (() -> InfisicalCredential?)? = nil,
        credentialWriter: ((InfisicalCredential) throws -> Void)? = nil,
        credentialRemover: (() throws -> Void)? = nil,
        legacyMigration: InfisicalLegacyCredentialMigration? = nil,
        legacyDraftReader: (@MainActor () -> InfisicalCredential?)? = nil
    ) {
        self.client = client
        self.store = store
        self.credentialProvider = credentialProvider
        let migration = legacyMigration ?? (MaintainStore.isRunningUnderTest ? .inert : .persistent)
        self.legacyMigration = migration
        self.keychainReader = { InfisicalSettings.readCredentialFromKeychainSilently() }
        self.legacyDraftReader = legacyDraftReader ?? (MaintainStore.isRunningUnderTest ? { nil } : Self.readLegacyDraft)
        self.credentialWriter = credentialWriter ?? Self.writeCredential
        self.credentialRemover = credentialRemover ?? Self.removeCredential
    }

    // MARK: - Lifecycle

    /// Call once at launch.  Never blocks: the fetch runs async, and an
    /// unconfigured or unreachable Infisical leaves every built-in default
    /// and UserDefaults value exactly as it was.
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let credential = credential() {
            isConfigured = true
            projectId = credential.effectiveProjectId
            authMode = credential.effectiveMode
            // Reconcile persisted effective values before the first network suspension.
            // This also protects a launch after a Keychain save interrupted by process exit.
            store.selectProject(credential.cacheTargetId)
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
            await refresh()
        } else {
            // Resolve startup to local mode so scoped fallback cannot leak and
            // local edits remain persistable when the Keychain is unavailable.
            store.selectProject(InfisicalStore.localProjectId)
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
        }
        startRefreshTimer()
        if !MaintainStore.isRunningUnderTest {
            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshIfStale(minimumGap: 30)
                }
            }
        }
    }

    /// Full fetch: login, then secrets, then replace the cache.  A failure
    /// logs loudly (lastError, for the Advanced tab) but keeps serving the
    /// last-known-good cache -- staleness is safer than an outage.
    func refresh() async {
        guard !isRefreshing, !isSaving else { return }
        guard let credential = credential() else {
            isConfigured = false
            return
        }
        isConfigured = true
        isRefreshing = true
        let requestGeneration = generation
        defer { if generation == requestGeneration { isRefreshing = false } }
        do {
            let result = try await fetchConfiguration(credential, expectedGeneration: requestGeneration)
            let secrets = result.values
            guard generation == requestGeneration else { return }
            store.replace(secrets, projectId: credential.cacheTargetId)
            keyPaths = result.paths
            hasLoadedRoutes = true
            lastRefresh = Date()
            lastError = nil
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
        } catch {
            // Only this connection may update its cache or status.
            guard generation == requestGeneration else { return }
            lastError = Self.safeMessage(for: error)
        }
    }

    /// Write-through for an admin save.  The Infisical PATCH happens FIRST;
    /// the local cache updates only after it succeeds.  A failed write
    /// throws and the save must be treated as failed -- the cache and
    /// Infisical never diverge silently.
    func set(_ value: String, forKey key: String, expectedGeneration: UUID? = nil) async throws {
        if let expectedGeneration, expectedGeneration != generation { throw InfisicalError.configurationChanged }
        guard !isSaving else { throw InfisicalError.saveInProgress }
        guard let credential = credential() else { throw InfisicalError.notConfigured }
        let requestGeneration = generation
        do {
            let path = keyPaths[key] ?? credential.effectivePath
            let token: String
            switch credential.effectiveMode {
            case .machineIdentity:
                token = try await client.login(clientId: credential.clientId, clientSecret: credential.clientSecret)
            case .serviceTokens:
                // Offline relaunch has no key-to-folder provenance yet.  Never guess.
                guard hasLoadedRoutes else { throw InfisicalError.invalidScope }
                let matches = credential.activeTokens.filter { $0.writes && $0.secretPath == path }
                guard matches.count == 1, let entry = matches.first else { throw InfisicalError.readOnly }
                let metadata = try await client.tokenMetadata(token: entry.token)
                guard metadata.validates(entry, environment: Self.environment) else { throw InfisicalError.invalidScope }
                token = entry.token
            }
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            try await client.upsertSecret(
                accessToken: token, environment: Self.environment, key: key, value: value,
                projectId: credential.effectiveProjectId, secretPath: path
            )
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            store.set(value, forKey: key)
            keyPaths[key] = path
        } catch {
            if generation == requestGeneration { lastError = Self.safeMessage(for: error) }
            throw error
        }
    }

    /// Validate authority before reads; never infer scope from a secrets response.
    private func fetchConfiguration(_ credential: InfisicalCredential, expectedGeneration: UUID, validateAllTokens: Bool = false) async throws -> (values: [String: String], paths: [String: String]) {
        if credential.effectiveMode == .machineIdentity {
            let token = try await client.login(clientId: credential.clientId, clientSecret: credential.clientSecret)
            guard generation == expectedGeneration else { throw InfisicalError.configurationChanged }
            let values = try await client.fetchSecrets(accessToken: token, environment: Self.environment,
                projectId: credential.effectiveProjectId, secretPath: credential.effectivePath)
            return (values, Dictionary(uniqueKeysWithValues: values.keys.map { ($0, credential.effectivePath) }))
        }
        // Candidate saves verify every entry; routine refreshes use only the active project.
        let tokensToValidate = validateAllTokens ? (credential.serviceTokens ?? []) : credential.activeTokens
        for entry in tokensToValidate {
            guard generation == expectedGeneration else { throw InfisicalError.configurationChanged }
            let metadata = try await client.tokenMetadata(token: entry.token)
            guard metadata.validates(entry, environment: Self.environment) else { throw InfisicalError.invalidScope }
        }
        let entries = credential.activeTokens
        let reads = entries.filter(\.reads)
        guard !reads.isEmpty,
              Set(reads.map(\.secretPath)).count == reads.count,
              Set(entries.filter(\.writes).map(\.secretPath)).count == entries.filter(\.writes).count
        else { throw InfisicalError.invalidScope }
        // Write folders must also be readable so a saved value cannot vanish at refresh.
        let writers = entries.filter(\.writes)
        guard writers.allSatisfy({ entry in reads.contains { $0.secretPath == entry.secretPath } }),
              writers.isEmpty || writers.contains(where: { $0.secretPath == credential.effectivePath })
        else { throw InfisicalError.invalidScope }
        var values: [String: String] = [:]
        var paths: [String: String] = [:]
        for entry in reads {
            guard generation == expectedGeneration else { throw InfisicalError.configurationChanged }
            let fetched = try await client.fetchSecrets(accessToken: entry.token, environment: Self.environment,
                projectId: credential.effectiveProjectId, secretPath: entry.secretPath)
            for (key, value) in fetched {
                guard paths[key] == nil else { throw InfisicalError.ambiguousKey }
                values[key] = value
                paths[key] = entry.secretPath
            }
        }
        return (values, paths)
    }

    /// Do not expose response bodies, transport details, or arbitrary errors.
    static func safeMessage(for error: Error) -> String {
        (error as? InfisicalError)?.description ?? "Infisical operation failed"
    }

    // MARK: - Refresh scheduling

    private func startRefreshTimer() {
        timer?.invalidate()
        // Tick every minute; the actual refresh runs when the tunable
        // interval (default 5 minutes) has elapsed since the last success.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshIfDue()
            }
        }
    }

    func refreshIfDue() async {
        guard backgroundRefreshAllowed else { return }
        let minutes = store.double(for: InfisicalKey.settingsRefreshMinutes) ?? 5
        let interval = max(60, minutes * 60)
        await refreshIfStale(minimumGap: interval)
    }

    private func refreshIfStale(minimumGap: TimeInterval) async {
        guard backgroundRefreshAllowed, !isRefreshing else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minimumGap { return }
        await refresh()
    }

    /// Timer and become-active refresh must not raise a Keychain prompt.
    /// An injected credential never touches the Keychain, so it may refresh
    /// even though the memory cache is empty.  A cached credential refreshes
    /// from memory.  A terminal miss stays quiet.  A transient miss (locked,
    /// or interaction suppressed) stays retryable so unlock can recover.
    private var backgroundRefreshAllowed: Bool {
        if let provider = credentialProvider {
            return provider()?.isOperational == true
        }
        if inMemoryCredential != nil { return true }
        return !keychainReadAttempted
    }

    // MARK: - Credential (Keychain)

    private var inMemoryCredential: InfisicalCredential?
    private var keychainReadAttempted = false

    private func credential() -> InfisicalCredential? {
        if credentialWasCleared { return nil }
        if let cached = inMemoryCredential { return cached }
        if let provider = credentialProvider {
            let loaded = provider()
            lastKeychainRead = .init(credential: loaded, terminal: true, absent: loaded == nil)
            guard let loaded, loaded.isOperational else { return nil }
            inMemoryCredential = loaded
            return loaded
        }
        guard !keychainReadAttempted else { return nil }
        let read = keychainReader()
        lastKeychainRead = read
        inMemoryCredential = read.credential.flatMap { $0.isOperational ? $0 : nil }
        // Latch only after the Keychain answers.  A transient status must
        // stay retryable; latching before the read made a locked launch
        // or a suppressed prompt permanent for the process lifetime.
        if read.terminal {
            keychainReadAttempted = true
        }
        guard let loaded = read.credential, loaded.isOperational else { return nil }
        return loaded
    }

    private static let keychainService = "com.simplewithus.hoghunter.infisical"
    private static let keychainAccount = "universal-auth"

    /// The one place the client secret is accepted: typed in by the admin,
    /// then stored in the Keychain.  Never in the binary, never in
    /// UserDefaults, never in a file.
    func saveCredential(clientId: String, clientSecret: String, projectId: String) async throws {
        try await saveConfiguration(InfisicalCredential(clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret, projectId: projectId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), mode: .machineIdentity))
    }

    func saveConfiguration(_ configuration: InfisicalCredential) async throws {
        guard !isSaving else { throw InfisicalError.saveInProgress }
        var candidate = configuration
        candidate.projectId = configuration.effectiveProjectId
        candidate.mode = configuration.effectiveMode
        if candidate.effectiveMode == .serviceTokens {
            candidate.clientId = ""
            candidate.clientSecret = ""
        } else {
            candidate.clientId = candidate.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.serviceTokens = nil
        }
        guard candidate.isComplete else { throw InfisicalError.invalidConfiguration }
        let requestGeneration = generation
        let saveID = UUID()
        activeSave = saveID
        isSaving = true
        defer {
            if activeSave == saveID {
                activeSave = nil
                isSaving = false
            }
        }
        do {
            let result = try await fetchConfiguration(candidate, expectedGeneration: requestGeneration, validateAllTokens: true)
            let secrets = result.values
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            // Update the existing record atomically; a failed save keeps the working connection.
            try credentialWriter(candidate)
            legacyMigration.retire()
            generation = UUID()
            inMemoryCredential = candidate
            lastKeychainRead = .init(credential: candidate, terminal: true)
            hasCredentialDraft = false
            keychainReadAttempted = false
            credentialWasCleared = false
            self.projectId = candidate.effectiveProjectId
            authMode = candidate.effectiveMode
            keyPaths = result.paths
            hasLoadedRoutes = true
            isConfigured = true
            isRefreshing = false
            // Replace, never merge: nothing from the previous target survives.
            store.replace(secrets, projectId: candidate.cacheTargetId)
            lastRefresh = Date()
            lastError = nil
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
        } catch {
            if generation == requestGeneration { lastError = Self.safeMessage(for: error) }
            throw error
        }
    }

    // MARK: - Keychain Storage And Editor-Only Legacy Drafts

    private static let appGroupIdentifier = "group.com.simplewithus.hoghunter"
    private static let fileName = "infisical.json"

    static var appGroupStorageURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    static var applicationSupportStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HogHunter", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func writeCredential(_ credential: InfisicalCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw InfisicalError.credentialStorage }
        // Retire file copies only after Keychain confirms the replacement.
        for url in [appGroupStorageURL, applicationSupportStorageURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func clearCredential() throws {
        try credentialRemover()
        legacyMigration.retire()
        generation = UUID()
        credentialWasCleared = true
        activeSave = nil
        isSaving = false
        inMemoryCredential = nil
        lastKeychainRead = .init(credential: nil, terminal: true, absent: true)
        hasCredentialDraft = false
        keychainReadAttempted = true
        isConfigured = false
        isRefreshing = false
        projectId = ""
        authMode = .machineIdentity
        keyPaths = [:]
        hasLoadedRoutes = false
        store.replace([:], projectId: InfisicalStore.localProjectId)
        lastRefresh = nil
        lastError = nil
        NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
    }

    private static func removeCredential() throws {
        // A failed Keychain removal remains a failed clear.  Once it succeeds,
        // the caller retires file drafts permanently even if unlink fails.
        try removeCredentialFromKeychain()
        for url in [appGroupStorageURL, applicationSupportStorageURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func removeCredentialFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InfisicalError.decoding("Keychain removal failed (OSStatus \(status))")
        }
    }

    /// `errSecSuccess` and `errSecItemNotFound` are answers.  Every other
    /// status (locked Keychain, interaction suppressed, auth failure) is
    /// transient and must not latch.  Pure, so it stays `nonisolated` and
    /// synchronous tests can call it off the main actor.
    nonisolated static func isTerminalKeychainStatus(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    private static func readLegacyDraft() -> InfisicalCredential? {
        for url in [appGroupStorageURL, applicationSupportStorageURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let draft = try? JSONDecoder().decode(InfisicalCredential.self, from: data),
               draft.effectiveMode == .machineIdentity { return draft }
        }
        return nil
    }

    private static func readCredentialFromKeychainSilently() -> KeychainCredentialRead {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard isTerminalKeychainStatus(status) else {
            return KeychainCredentialRead(credential: nil, terminal: false)
        }
        if status == errSecItemNotFound { return KeychainCredentialRead(credential: nil, terminal: true, absent: true) }
        guard status == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(InfisicalCredential.self, from: data)
        else {
            return KeychainCredentialRead(credential: nil, terminal: true)
        }
        // Retain decoded inherited/incomplete data only for the secure editor.
        // credential() separately requires an explicit validated mode to activate it.
        return KeychainCredentialRead(credential: credential, terminal: true)
    }
}
