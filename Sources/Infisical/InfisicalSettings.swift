import AppKit
import Foundation
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

    /// Every non-secret key, for the Advanced tab's "push current values" seed.
    static let allNonSecret: [String] = [
        refreshInterval, alertThresholdPercent, alertSustainedMinutes, alertCooldownMinutes,
        reclaimCriticalFreeGb, reclaimAcuteFreeGb, reclaimHealthyFreeGb,
        reclaimCpuIdleFloorPercent, reclaimSwapUsedPct, reclaimLoad1Threshold,
        regimenIntervalHours, regimenTargetsPerChunk, regimenChunkPauseSeconds,
        regimenPressuredTargetsPerChunk, regimenPressuredChunkPauseSeconds,
        regimenExpensiveTierFreeGb, settingsRefreshMinutes,
    ]
}

/// Built-in defaults for every migrated key.  These are the values the repo
/// shipped with; they are also seeded into the Infisical project's dev
/// environment, so a configured app and an unconfigured app agree until an
/// admin changes something.
enum InfisicalDefaults {
    static let values: [String: String] = [
        InfisicalKey.refreshInterval: "3",
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

    var description: String {
        switch self {
        case .transport: return "Infisical network request failed"
        case .httpStatus(let code, _): return "Infisical request failed (HTTP \(code))"
        case .decoding(let what): return "could not decode \(what)"
        case .notConfigured: return "Infisical is not configured (no credential in Keychain)"
        case .invalidConfiguration: return "Enter a Client ID, Client Secret, and valid Project ID"
        case .configurationChanged: return "The Infisical connection changed; try again"
        case .saveInProgress: return "An Infisical connection save is already in progress"
        }
    }
}

// MARK: - Universal-auth credential

struct InfisicalCredential: Codable {
    var clientId: String
    var clientSecret: String
    /// Older records without this field remain unconfigured until explicitly saved.
    var projectId: String? = nil

    var effectiveProjectId: String { (projectId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var isComplete: Bool {
        !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UUID(uuidString: effectiveProjectId) != nil
    }
}

protocol InfisicalServing {
    func login(clientId: String, clientSecret: String) async throws -> String
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String]
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws
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

    /// Full settings set for the environment, as key -> value.
    func fetchSecrets(accessToken: String, environment: String, projectId: String) async throws -> [String: String] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v3/secrets/raw"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "workspaceId", value: projectId),
            URLQueryItem(name: "environment", value: environment),
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
    /// in the path (PATCH /api/v3/secrets/{name}); the caller must already
    /// hold a valid access token.
    func upsertSecret(accessToken: String, environment: String, key: String, value: String, projectId: String) async throws {
        var url = baseURL.appendingPathComponent("/api/v3/secrets")
        url.appendPathComponent(key)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "workspaceId": projectId,
            "environment": environment,
            "secretValue": value,
        ])
        let (data, response) = try await perform(request)
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
final class InfisicalStore {
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

    /// The app has a single deployment (this Mac), so it reads the dev
    /// environment -- the environment the fleet seeds.  staging/prod exist
    /// for future use; see INFISICAL.md.
    static let environment = "dev"

    @Published private(set) var isConfigured = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var projectId = ""

    private let client: InfisicalServing
    private let store: InfisicalStore
    private let credentialWriter: (InfisicalCredential) throws -> Void
    private let credentialRemover: () throws -> Void
    private var generation = UUID()
    private var activeSave: UUID?

    /// Capture before scheduling work, so an old UI edit cannot target a newer connection.
    var connectionGeneration: UUID { generation }
    var snapshot: (projectId: String?, values: [String: String]) { store.snapshot }
    private var credentialWasCleared = false
    /// Injectable for tests; nil means "read the Keychain".
    var credentialProvider: (() -> InfisicalCredential?)?
    private var timer: Timer?
    private var bootstrapped = false
    private var becomeActiveObserver: NSObjectProtocol?

    init(
        client: InfisicalServing = InfisicalClient(),
        store: InfisicalStore = .shared,
        credentialProvider: (() -> InfisicalCredential?)? = nil,
        credentialWriter: ((InfisicalCredential) throws -> Void)? = nil,
        credentialRemover: (() throws -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.credentialProvider = credentialProvider
        self.credentialWriter = credentialWriter ?? Self.writeCredentialToKeychain
        self.credentialRemover = credentialRemover ?? Self.removeCredentialFromKeychain
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
            // Reconcile persisted effective values before the first network suspension.
            // This also protects a launch after a Keychain save interrupted by process exit.
            store.selectProject(projectId)
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
            await refresh()
        } else {
            // Resolve startup to local mode so scoped fallback cannot leak and
            // local edits remain persistable when the Keychain is unavailable.
            store.selectProject(InfisicalStore.localProjectId)
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
        }
        startRefreshTimer()
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
            let token = try await client.login(
                clientId: credential.clientId,
                clientSecret: credential.clientSecret
            )
            guard generation == requestGeneration else { return }
            let secrets = try await client.fetchSecrets(
                accessToken: token,
                environment: Self.environment,
                projectId: credential.effectiveProjectId
            )
            guard generation == requestGeneration else { return }
            store.replace(secrets, projectId: credential.effectiveProjectId)
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
            let token = try await client.login(clientId: credential.clientId, clientSecret: credential.clientSecret)
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            try await client.upsertSecret(
                accessToken: token, environment: Self.environment, key: key, value: value,
                projectId: credential.effectiveProjectId
            )
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            store.set(value, forKey: key)
        } catch {
            if generation == requestGeneration { lastError = Self.safeMessage(for: error) }
            throw error
        }
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

    private func refreshIfDue() async {
        guard isConfigured else { return }
        let minutes = store.double(for: InfisicalKey.settingsRefreshMinutes) ?? 5
        let interval = max(60, minutes * 60)
        await refreshIfStale(minimumGap: interval)
    }

    private func refreshIfStale(minimumGap: TimeInterval) async {
        guard isConfigured, !isRefreshing else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minimumGap { return }
        await refresh()
    }

    // MARK: - Credential (Keychain)

    private var inMemoryCredential: InfisicalCredential?

    private func credential() -> InfisicalCredential? {
        if credentialWasCleared { return nil }
        if let cached = inMemoryCredential { return cached }
        if let provider = credentialProvider {
            guard let loaded = provider(), loaded.isComplete else { return nil }
            inMemoryCredential = loaded
            return loaded
        }
        guard let loaded = Self.readCredentialFromKeychain(), loaded.isComplete else { return nil }
        inMemoryCredential = loaded
        return loaded
    }

    private static let keychainService = "com.simplewithus.hoghunter.infisical"
    private static let keychainAccount = "universal-auth"

    /// The one place the client secret is accepted: typed in by the admin,
    /// then stored in the Keychain.  Never in the binary, never in
    /// UserDefaults, never in a file.
    func saveCredential(clientId: String, clientSecret: String, projectId: String) async throws {
        guard !isSaving else { throw InfisicalError.saveInProgress }
        let clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = projectId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clientId.isEmpty,
              !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UUID(uuidString: projectId) != nil else { throw InfisicalError.invalidConfiguration }
        let candidate = InfisicalCredential(clientId: clientId, clientSecret: clientSecret, projectId: projectId)
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
            // A valid identity alone is insufficient: verify project + dev read access.
            let token = try await client.login(clientId: candidate.clientId, clientSecret: candidate.clientSecret)
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            let secrets = try await client.fetchSecrets(
                accessToken: token, environment: Self.environment, projectId: candidate.effectiveProjectId
            )
            guard generation == requestGeneration else { throw InfisicalError.configurationChanged }
            // Update the existing record atomically; a failed save keeps the working connection.
            try credentialWriter(candidate)
            generation = UUID()
            inMemoryCredential = candidate
            credentialWasCleared = false
            self.projectId = candidate.effectiveProjectId
            isConfigured = true
            isRefreshing = false
            // Replace, never merge: nothing from the previous target survives.
            store.replace(secrets, projectId: candidate.effectiveProjectId)
            lastRefresh = Date()
            lastError = nil
            NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
        } catch {
            if generation == requestGeneration { lastError = Self.safeMessage(for: error) }
            throw error
        }
    }

    private static func writeCredentialToKeychain(_ credential: InfisicalCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw InfisicalError.decoding("Keychain save failed (OSStatus \(status))")
        }
    }

    func clearCredential() throws {
        try credentialRemover()
        generation = UUID()
        credentialWasCleared = true
        activeSave = nil
        isSaving = false
        inMemoryCredential = nil
        isConfigured = false
        isRefreshing = false
        projectId = ""
        store.replace([:], projectId: InfisicalStore.localProjectId)
        lastRefresh = nil
        lastError = nil
        NotificationCenter.default.post(name: .infisicalSettingsDidRefresh, object: self)
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

    private static func readCredentialFromKeychain() -> InfisicalCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(InfisicalCredential.self, from: data),
              !credential.clientId.isEmpty, !credential.clientSecret.isEmpty
        else { return nil }
        return credential
    }
}
