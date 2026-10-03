import Foundation

/// A configurable, unattended cleaning regimen.
///
/// The owner ruling of 2026-10-02 is the reason this type exists in this shape:
///
/// > swap high should mean that you do the same stuff you otherwise would but
/// > just divide the tasks into maybe 2-4 separate smaller tasks...  always
/// > avoiding cleaning when load is high when I always have load high will
/// > just mean rarely cleaning
///
/// The previous engine keyed a binary "do less" gate on `load1 > 40`.  On a
/// machine whose normal load sits at 15-30 that gate was true almost always,
/// so the regimen effectively never ran.  A guard whose threshold equals the
/// normal state is an outage, not a guard.
///
/// So pressure here changes the **shape** of the run -- chunk size and pause
/// -- and never its **scope**.  `enabledRules` is the same rule list a manual
/// clean would use.  The only thing pressure may ever close is the
/// `expensive` tier, and only on real space pressure.
///
/// Deleting caches never reduces swap.  That is still true, and it constrains
/// what *fixes* swap -- not how much regenerable waste a regimen may clear.
struct CleanRegimen: Codable, Equatable, Sendable {

    // MARK: - Schedule

    /// Whether the regimen may run unattended at all.  Off by default: an
    /// unattended delete is a different promise than a button press, so the
    /// owner opts in rather than getting it by upgrade.
    var isEnabled: Bool = false

    /// Hours between runs, counted from the end of the previous one.  A
    /// regimen that takes longer than its own interval is not a schedule.
    var intervalHours: Double = 24

    /// Only run when the machine has been idle this long.  A scheduled
    /// reclaim on a machine someone is actively using is the case the
    /// original design got wrong.
    var requireIdleMinutes: Double = 30

    /// Never start when a build is in flight.  Bulk I/O during `xcodebuild`
    /// is what made the old `--pressure` path time out.
    var avoidDuringBuilds: Bool = true

    // MARK: - Scope

    /// Which reclaim rules the regimen may run.  Mirrors the engine's rule
    /// names so a user reading either surface sees the same vocabulary.
    var enabledRules: Set<String> = CleanRegimen.defaultRules

    /// Never run without the user present.  When true the regimen only does
    /// work while the panel is open.
    var requireUserPresent: Bool = false

    // MARK: - Pacing

    /// Targets applied per chunk when the machine is calm.
    var targetsPerChunk: Int = 3

    /// Seconds to pause between chunks when calm.
    var chunkPauseSeconds: Double = 5

    /// Applied above `swap`/`load` pressure.  This is a *smaller burst*, not
    /// a skipped run.
    var pressuredTargetsPerChunk: Int = 2

    var pressuredChunkPauseSeconds: Double = 10

    // MARK: - Safety

    /// Take a local APFS snapshot before an unattended clean.  On by default:
    /// an unattended delete without a rollback point is not recoverable.
    var createSnapshotBeforeClean: Bool = true

    /// Free space below which the `expensive` tier opens.  Bulk deletes are
    /// the biggest win and the biggest I/O burst, so they stay tied to real
    /// space pressure.
    var expensiveTierFreeGB: Double = 40

    // MARK: - Defaults

    /// Explicit memberwise-style defaults initializer.
    ///
    /// Declaring `init(from decoder:)` below suppresses Swift's synthesized
    /// memberwise init, so this is spelled out.  Every property falls back to
    /// the field's declared default, which is what makes partial JSON
    /// decoding work.
    init(
        isEnabled: Bool = false,
        intervalHours: Double = 24,
        requireIdleMinutes: Double = 30,
        avoidDuringBuilds: Bool = true,
        enabledRules: Set<String> = CleanRegimen.defaultRules,
        requireUserPresent: Bool = false,
        targetsPerChunk: Int = 3,
        chunkPauseSeconds: Double = 5,
        pressuredTargetsPerChunk: Int = 2,
        pressuredChunkPauseSeconds: Double = 10,
        createSnapshotBeforeClean: Bool = true,
        expensiveTierFreeGB: Double = 40
    ) {
        self.isEnabled = isEnabled
        self.intervalHours = intervalHours
        self.requireIdleMinutes = requireIdleMinutes
        self.avoidDuringBuilds = avoidDuringBuilds
        self.enabledRules = enabledRules
        self.requireUserPresent = requireUserPresent
        self.targetsPerChunk = targetsPerChunk
        self.chunkPauseSeconds = chunkPauseSeconds
        self.pressuredTargetsPerChunk = pressuredTargetsPerChunk
        self.pressuredChunkPauseSeconds = pressuredChunkPauseSeconds
        self.createSnapshotBeforeClean = createSnapshotBeforeClean
        self.expensiveTierFreeGB = expensiveTierFreeGB
    }

    /// The engine's rule names.  `ask-first` is deliberately absent: nothing
    /// in that tier is ever deleted without a human, so a regimen has no
    /// business listing it.
    static let defaultRules: Set<String> = [
        "temp-scratch", "app-staging", "dev-caches",
        "xcode-artifacts", "logs", "sqlite-wal", "brew",
    ]

    /// Rules a regimen is allowed to schedule.  `ask-first` and `expensive`
    /// bulk work are not in here; the expensive tier is a *property of disk
    /// pressure*, not a rule the user enables.
    static let schedulableRules: [String] = [
        "snapshots", "temp-scratch", "app-staging", "dev-caches",
        "xcode-artifacts", "simulator-runtimes", "logs", "sqlite-wal", "brew",
    ]

    var isValid: Bool {
        intervalHours > 0
            && intervalHours <= 24 * 14
            && targetsPerChunk >= 1
            && pressuredTargetsPerChunk >= 1
            && chunkPauseSeconds >= 0
            && pressuredChunkPauseSeconds >= 0
    }

    /// Clamp a possibly-corrupt decoded regimen back into a runnable shape.
    /// A persisted JSON blob edited by hand, or written by a future build
    /// with different fields, must never be able to wedge the scheduler.
    func sanitized() -> CleanRegimen {
        var copy = self
        copy.intervalHours = intervalHours.isFinite && intervalHours > 0
            ? min(intervalHours, 24 * 14) : 24
        copy.targetsPerChunk = max(1, targetsPerChunk)
        copy.pressuredTargetsPerChunk = max(1, pressuredTargetsPerChunk)
        copy.chunkPauseSeconds = chunkPauseSeconds.isFinite ? max(0, chunkPauseSeconds) : 5
        copy.pressuredChunkPauseSeconds = pressuredChunkPauseSeconds.isFinite
            ? max(0, pressuredChunkPauseSeconds) : 10
        copy.requireIdleMinutes = max(0, requireIdleMinutes)
        copy.expensiveTierFreeGB = max(1, expensiveTierFreeGB)
        copy.enabledRules = enabledRules.intersection(Self.schedulableRules)
        return copy
    }

    // MARK: - Persistence

    private static let defaultsKey = "hoghunter.cleaner.regimen"
    private static let suiteName = "group.com.simplewithus.hoghunter"

    /// Regimens are a non-trivial Codable payload, so they follow the
    /// `CleanerExclusions` pattern -- a JSON blob in the shared suite --
    /// rather than the flat `@AppStorage` string keys the simple settings use.
    static func load() -> CleanRegimen {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey) else {
            return CleanRegimen()
        }
        // A decode failure returns the default rather than throwing: a corrupt
        // blob must not stop the app from launching.
        return (try? JSONDecoder().decode(CleanRegimen.self, from: data)) ?? CleanRegimen()
    }

    func save() {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Decode a regimen, tolerating fields this build does not know about.
    ///
    /// The synthesized `Codable` conformance throws `keyNotFound` the moment
    /// it meets a field it has no mapping for, which means a regimen written
    /// by a *newer* build would fail to load here and silently reset a user's
    /// carefully configured schedule back to defaults -- with no error shown.
    /// That is the same class of silent-reset as the load gate this whole file
    /// exists to correct, so it is worth the few lines.
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self)
        var regimen = CleanRegimen()
        regimen.isEnabled = try raw.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? regimen.isEnabled
        regimen.intervalHours = try raw.decodeIfPresent(Double.self, forKey: .intervalHours) ?? regimen.intervalHours
        regimen.requireIdleMinutes = try raw.decodeIfPresent(Double.self, forKey: .requireIdleMinutes) ?? regimen.requireIdleMinutes
        regimen.avoidDuringBuilds = try raw.decodeIfPresent(Bool.self, forKey: .avoidDuringBuilds) ?? regimen.avoidDuringBuilds
        if let rules = try? raw.decode(Set<String>.self, forKey: .enabledRules) {
            regimen.enabledRules = rules
        }
        regimen.requireUserPresent = try raw.decodeIfPresent(Bool.self, forKey: .requireUserPresent) ?? regimen.requireUserPresent
        regimen.targetsPerChunk = try raw.decodeIfPresent(Int.self, forKey: .targetsPerChunk) ?? regimen.targetsPerChunk
        regimen.chunkPauseSeconds = try raw.decodeIfPresent(Double.self, forKey: .chunkPauseSeconds) ?? regimen.chunkPauseSeconds
        regimen.pressuredTargetsPerChunk = try raw.decodeIfPresent(Int.self, forKey: .pressuredTargetsPerChunk) ?? regimen.pressuredTargetsPerChunk
        regimen.pressuredChunkPauseSeconds = try raw.decodeIfPresent(Double.self, forKey: .pressuredChunkPauseSeconds) ?? regimen.pressuredChunkPauseSeconds
        regimen.createSnapshotBeforeClean = try raw.decodeIfPresent(Bool.self, forKey: .createSnapshotBeforeClean) ?? regimen.createSnapshotBeforeClean
        regimen.expensiveTierFreeGB = try raw.decodeIfPresent(Double.self, forKey: .expensiveTierFreeGB) ?? regimen.expensiveTierFreeGB
        self = regimen
    }
}
