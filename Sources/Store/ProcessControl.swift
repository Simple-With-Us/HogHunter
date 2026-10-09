import AppKit
import Darwin
import Foundation

/// Quitting or taming a process, deliberately.  Every member is re-checked
/// against the live process table at the moment of the action, so a pid that
/// was recycled between the last sample and the click is never signalled.
/// There is deliberately no entry point that takes a bare pid: the check needs
/// the start time the member was sampled with.
enum ProcessControl {
    /// Processes that keep the desktop alive.  Quitting any of these is a bad
    /// day, so the button is never offered for them.
    static let denylistedNames: Set<String> = [
        "kernel_task",
        "launchd",
        "WindowServer",
        "loginwindow",
        "Finder",
        "Dock",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "coreaudiod",
        // The executable inside the bundle is still named HogHunter, so this
        // is what the process table reports.  "Hog Hunter" is listed too
        // because a sample can also pick up the bundle's display name.
        "HogHunter",
        "Hog Hunter",
    ]

    static let systemProcessReason = "system process"
    static let otherUserReason = "owned by another user"
    static let thisAppReason = "this app"

    /// Why Quit is unavailable for a sample, or nil when it is available.
    static func blockReason(for sample: ProcessSample) -> String? {
        blockReason(pid: sample.key.pid, uid: sample.uid, name: sample.name)
    }

    static func blockReason(pid: pid_t, uid: uid_t, name: String) -> String? {
        if pid == getpid() { return thisAppReason }
        if pid <= 1 { return systemProcessReason }
        if denylistedNames.contains(name) { return systemProcessReason }
        if uid != getuid() { return otherUserReason }
        return nil
    }

    enum Outcome: Equatable {
        /// A quit request was delivered.
        case asked
        /// The process was killed outright.
        case forced
        /// The pid no longer belongs to the process we sampled.
        case changed
        /// Blocked by ownership, the denylist, or being Hog Hunter itself.
        case blocked(String)
        case failed(String)

        var isAction: Bool {
            switch self {
            case .asked, .forced: return true
            case .changed, .blocked, .failed: return false
            }
        }
    }

    struct MemberResult {
        var key: ProcessKey
        var name: String
        var outcome: Outcome
    }

    struct QuitOutcome {
        var results: [MemberResult]
        /// What was done, for messages: "quit", "tamed", or "restored".
        var pastTense = "quit"

        var actedOn: Int { results.filter { $0.outcome.isAction }.count }

        /// A one-line explanation for the panel, or nil when everything worked.
        var message: String? {
            if results.isEmpty {
                return "That hog is only in history.\u{00A0} Switch to Now to act on a live process."
            }
            var reasons: [String] = []
            for result in results {
                switch result.outcome {
                case .changed: reasons.append("\(result.name) changed since sampling")
                case .blocked(let why): reasons.append("\(result.name) is \(why)")
                case .failed(let why): reasons.append("\(result.name): \(why)")
                case .asked, .forced: continue
                }
            }
            guard !reasons.isEmpty else { return nil }
            let listed = reasons.prefix(3).joined(separator: ", ")
            let extra = reasons.count > 3 ? ", and \(reasons.count - 3) more" : ""
            if actedOn == 0 { return "Nothing was \(pastTense): \(listed)\(extra)." }
            return "\(pastTense.capitalized) \(actedOn), skipped \(listed)\(extra)."
        }
    }

    /// Asks every live member of `row` to quit, or kills it when `force`.
    static func quit(_ row: HogRow, force: Bool) -> QuitOutcome {
        quit(members: row.keys, fallbackName: row.name, force: force)
    }

    /// Asks every live member to quit, or kills it when `force`.  A member
    /// whose pid now belongs to a different process is reported as changed
    /// and left alone.
    static func quit(members: [ProcessKey], fallbackName: String, force: Bool) -> QuitOutcome {
        apply(to: members, fallbackName: fallbackName, pastTense: "quit") { pid in
            send(to: pid, force: force)
        }
    }

    // MARK: - Process Priority & Taming

    /// Checks whether a process is running with background scheduling / nice priority.
    static func isTamed(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        let prio = getpriority(PRIO_PROCESS, id_t(pid))
        if errno == 0 && prio >= 15 { return true }
        let darwinBg = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        return darwinBg == 1
    }

    /// Throttles every live member to background QoS and nice level 20.
    @discardableResult
    static func tame(members: [ProcessKey], fallbackName: String) -> QuitOutcome {
        apply(to: members, fallbackName: fallbackName, pastTense: "tamed") { pid in
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
            let res = setpriority(PRIO_PROCESS, id_t(pid), 20)
            return res == 0 ? .asked : .failed(String(cString: strerror(errno)))
        }
    }

    /// Restores standard scheduling priority to every live member.
    @discardableResult
    static func untame(members: [ProcessKey], fallbackName: String) -> QuitOutcome {
        apply(to: members, fallbackName: fallbackName, pastTense: "restored") { pid in
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
            let res = setpriority(PRIO_PROCESS, id_t(pid), 0)
            return res == 0 ? .asked : .failed(String(cString: strerror(errno)))
        }
    }

    /// The one place an action reaches a process.  Per member: the pid must
    /// still be the process that was sampled, then the block rules apply,
    /// then the action runs.
    private static func apply(
        to members: [ProcessKey],
        fallbackName: String,
        pastTense: String,
        _ action: (pid_t) -> Outcome
    ) -> QuitOutcome {
        var results: [MemberResult] = []
        for member in members {
            let name = currentName(member.pid) ?? fallbackName
            guard identityMatches(member) else {
                results.append(MemberResult(key: member, name: name, outcome: .changed))
                continue
            }
            let uid = currentUid(member.pid) ?? uid_t.max
            if let reason = blockReason(pid: member.pid, uid: uid, name: name) {
                results.append(MemberResult(key: member, name: name, outcome: .blocked(reason)))
                continue
            }
            results.append(MemberResult(key: member, name: name, outcome: action(member.pid)))
        }
        return QuitOutcome(results: results, pastTense: pastTense)
    }

    // MARK: - Live re-checks

    /// True when the pid still belongs to the process the key describes.  A key
    /// with no start time cannot be verified, so it is treated as changed.
    static func identityMatches(_ member: ProcessKey) -> Bool {
        guard member.startTime != 0 else { return false }
        return startTime(member.pid) == member.startTime
    }

    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        return result == 0 ? info.ri_proc_start_abstime : nil
    }

    private static func currentUid(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return uid_t(info.pbi_uid)
    }

    private static func currentName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    private static func send(to pid: pid_t, force: Bool) -> Outcome {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok { return force ? .forced : .asked }
        }
        if kill(pid, force ? SIGKILL : SIGTERM) == 0 {
            return force ? .forced : .asked
        }
        return .failed(String(cString: strerror(errno)))
    }
}
