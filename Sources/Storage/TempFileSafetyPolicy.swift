import Foundation
import Darwin
import CoreFoundation

/// A local deletion boundary, like cleaner exclusions.  Remote settings cannot edit it.
struct TempFileSafetyPolicy: Equatable, Sendable {
    static let defaultsKey = "hoghunter.cleaner.tempMinimumUntouchedHours"
    static let defaultHours: Double = 72
    static let allowedHours: ClosedRange<Double> = 1...8_760
    let minimumUntouchedHours: Double

    init(hours: Double = defaultHours) {
        minimumUntouchedHours = Self.isValid(hours) ? hours : Self.defaultHours
    }

    static func isValid(_ hours: Double) -> Bool {
        hours.isFinite && allowedHours.contains(hours) && hours.rounded() == hours
    }

    // Process-local generation catches A → B → A edits before queued actor
    // notifications run.  Every report remains bound to its starting generation.
    private static let revisionLock = NSLock()
    private static var revision: UInt64 = 0
    static var currentRevision: UInt64 {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return revision
    }

    var minimumUntouchedInterval: TimeInterval { minimumUntouchedHours * 3_600 }
    var hoursLabel: String { String(format: "%.0f", minimumUntouchedHours) }
    var categoryDescription: String {
        "Temporary files in /tmp untouched for at least \(hoursLabel) hours.  Preserves Git checkouts, source projects, staging, locks, and links."
    }

    private static func storedHours(from defaults: UserDefaults) -> Double? {
        guard let value = defaults.object(forKey: defaultsKey) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), isValid(value.doubleValue) else { return nil }
        return value.doubleValue
    }

    static func load(from defaults: UserDefaults = CleanerExclusions.sharedDefaults) -> Self {
        Self(hours: storedHours(from: defaults) ?? defaultHours)
    }

    @discardableResult
    static func save(hours: Double, to defaults: UserDefaults = CleanerExclusions.sharedDefaults) -> Self {
        // Invalid user edits cannot lower an existing stricter safety choice.
        guard isValid(hours) else { return load(from: defaults) }
        let policy = Self(hours: hours)
        let current = load(from: defaults)
        if policy == current {
            // An explicit default choice still survives a future default
            // change and repairs corrupt storage, without invalidating scans.
            if storedHours(from: defaults) == nil {
                defaults.set(policy.minimumUntouchedHours, forKey: defaultsKey)
            }
            return current
        }
        defaults.set(policy.minimumUntouchedHours, forKey: defaultsKey)
        revisionLock.lock()
        revision &+= 1
        revisionLock.unlock()
        NotificationCenter.default.post(name: .tempFileSafetyPolicyChanged, object: defaults)
        return policy
    }
}

extension Notification.Name {
    static let tempFileSafetyPolicyChanged = Notification.Name("hoghunter.tempFileSafetyPolicyChanged")
}

/// lstat does not follow the final entry's symlink.  Creation and change dates catch freshly
/// copied entries whose modification date was preserved.  File access counts;
/// directory access does not, because listing a directory can itself update it.
struct TempEntryMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let bytes: UInt64
    let modified: Date
    var latestActivity: Date

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
        let kind = info.st_mode & mode_t(S_IFMT)
        let isDirectory = kind == mode_t(S_IFDIR)
        let modified = date(info.st_mtimespec)
        var activity = max(modified, date(info.st_ctimespec), date(info.st_birthtimespec))
        if !isDirectory { activity = max(activity, date(info.st_atimespec)) }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                    isDirectory: isDirectory, isRegularFile: kind == mode_t(S_IFREG),
                    isSymbolicLink: kind == mode_t(S_IFLNK),
                    bytes: UInt64(max(0, info.st_blocks)) * 512,
                    modified: modified, latestActivity: activity)
    }
}
