import Foundation
import os

/// What the phone's server control routes run, after the router's gates.
///
/// The phone names an opaque row and an action.  Every argument the server sees
/// comes from here: the row is resolved against the Mac's own current reading,
/// checked with the same `can(action:)` the Mac's own menus use, and handed to
/// the same `ServerControl` and `ServerMaintenanceControl` they use, so nothing
/// from a request body reaches a shell.  An unknown row, a stale reading or a
/// protected row does nothing and says so.  The server's root audit log records
/// the action itself; `Audit` records who asked from which phone.
@MainActor
final class CompanionServerActions {
    /// One line of the Mac's log.  Never carries a token.
    struct AuditEntry: Equatable, Sendable {
        var device: String
        var action: String
        var row: String
        var outcome: String
    }

    typealias Audit = @Sendable (AuditEntry) -> Void
    typealias Reply = CompanionServer.Reply

    /// What one request came to: the reply, and what the log says about it.
    struct Answer: Error {
        var reply: Reply
        var row: String
        var outcome: String
    }

    nonisolated static let defaultAudit: Audit = { entry in
        logger.notice("Server action from \(entry.device, privacy: .public): \(entry.action, privacy: .public) on \(entry.row, privacy: .public): \(entry.outcome, privacy: .public)")
    }

    nonisolated private static let logger = Logger(subsystem: "com.simplewithus.hoghunter", category: "CompanionServerActions")

    /// The name `VPSProcess.can(action:)` and the server use for a phone action.
    nonisolated static func macAction(forProcess action: String) -> String {
        action == "forceQuit" ? "force-quit" : action
    }

    private let vps: VPSStatusStore
    private let control: ServerControl
    private let maintenance: ServerMaintenanceControl
    private let isMaintainRunning: () -> Bool
    private let audit: Audit
    private let now: () -> Date

    init(
        vps: VPSStatusStore,
        control: ServerControl,
        maintenance: ServerMaintenanceControl,
        isMaintainRunning: @escaping () -> Bool = { false },
        audit: @escaping Audit = CompanionServerActions.defaultAudit,
        now: @escaping () -> Date = Date.init
    ) {
        self.vps = vps
        self.control = control
        self.maintenance = maintenance
        self.isMaintainRunning = isMaintainRunning
        self.audit = audit
        self.now = now
    }

    func perform(_ request: CompanionServerActionRequest, device: String) async -> Reply {
        let action: String
        let result: Answer
        switch request {
        case .process(let rowId, let name):
            action = "process \(name)"
            result = await performProcess(rowId: rowId, action: name)
        case .workload(let rowId, let name):
            action = "workload \(name)"
            result = await performWorkload(rowId: rowId, action: name)
        case .maintain(let mode, let strategies, let acknowledged):
            action = "maintenance \(mode)"
            result = await performMaintenance(mode: mode, strategies: strategies, acknowledged: acknowledged)
        }
        audit(AuditEntry(device: device, action: action, row: result.row, outcome: result.outcome))
        return result.reply
    }

    // MARK: - Processes

    private func performProcess(rowId: String, action: String) async -> Answer {
        switch currentReading() {
        case .failure(let refusal):
            return refusal
        case .success(let (snapshot, host)):
            // Only the rows the phone could see: the same prefix the block sends.
            let rows = (snapshot.processes ?? []).prefix(CompanionServerStatusBuilder.processLimit)
            guard let process = rows.first(where: { CompanionServerStatusBuilder.opaqueID($0.id) == rowId }) else {
                return Self.changed()
            }
            let macAction = Self.macAction(forProcess: action)
            guard process.can(action: macAction) else {
                return Self.protected(process.protectionReason, name: process.name)
            }
            // The same rule the Mac's menu applies: acting on a process inside a
            // workload interrupts that workload, and the phone said so.
            let interrupts = !(process.container ?? "").isEmpty
            switch action {
            case "quit": await control.stop(process: process, host: host, allowWorkloadInterruption: interrupts)
            case "forceQuit": await control.stop(process: process, host: host, force: true, allowWorkloadInterruption: interrupts)
            case "tame": await control.tame(process: process, host: host, allowWorkloadInterruption: interrupts)
            case "untame": await control.untame(process: process, host: host, allowWorkloadInterruption: interrupts)
            case "sample": await control.sample(process: process, host: host)
            default: return Self.answer(400, CompanionServerActionResponse(status: "rejected", error: "That server action is not known."), row: process.name, outcome: "rejected")
            }
            return finish(name: process.name, sample: action == "sample")
        }
    }

    // MARK: - Workloads

    private func performWorkload(rowId: String, action: String) async -> Answer {
        switch currentReading() {
        case .failure(let refusal):
            return refusal
        case .success(let (snapshot, host)):
            let rows = (snapshot.coolify ?? []).prefix(CompanionServerStatusBuilder.workloadLimit)
            guard let resource = rows.first(where: { CompanionServerStatusBuilder.opaqueID($0.id) == rowId }) else {
                return Self.changed()
            }
            guard resource.can(action: action) else {
                return Self.protected(resource.protectionReason, name: resource.name)
            }
            switch action {
            case "stop": await control.stop(resource: resource, host: host, allowWorkloadInterruption: true)
            case "restart": await control.restart(resource: resource, host: host, allowWorkloadInterruption: true)
            default: return Self.answer(400, CompanionServerActionResponse(status: "rejected", error: "That server action is not known."), row: resource.name, outcome: "rejected")
            }
            return finish(name: resource.name, sample: false)
        }
    }

    /// Reads `ServerControl`'s outcome back into the phone's answer.
    private func finish(name: String, sample: Bool) -> Answer {
        // The Mac's own menus refresh after acting, so the next row the phone
        // sees has the server's new state.  A sample changes nothing.
        if !sample { vps.fetch(force: true) }
        switch control.lastOutcome {
        case .acted(let text):
            let response = CompanionServerActionResponse(status: "acted", message: text, name: name, sampleText: sample ? control.lastSampleText.flatMap(Self.phoneSampleText) : nil)
            return Self.answer(200, response, row: name, outcome: "acted")
        case .refused(let text):
            return Self.answer(409, CompanionServerActionResponse(status: "refused", error: text, name: name), row: name, outcome: "refused")
        case .failed(let text):
            // A transport failure says nothing about whether the server acted.
            return Self.answer(502, CompanionServerActionResponse(status: "unknown", error: text, name: name), row: name, outcome: "unconfirmed")
        case nil:
            return Self.answer(502, CompanionServerActionResponse(status: "unknown", error: "The Mac has no outcome to report.", name: name), row: name, outcome: "unconfirmed")
        }
    }

    // MARK: - Maintenance

    private func performMaintenance(mode: String, strategies: [String], acknowledged: Bool) async -> Answer {
        let row = "server maintenance"
        if case .failure(let refusal) = currentReading() { return refusal }
        // The same wait the Mac's card has: a Maintain run on this Mac can be
        // running its own remote step.
        guard !isMaintainRunning() else {
            return Self.answer(409, CompanionServerActionResponse(status: "busy", error: "A Maintain run is going on this Mac.\u{00A0} Wait for it to finish, then try again."), row: row, outcome: "busy")
        }
        let parsed = strategies.compactMap(ServerMaintenanceStrategy.init(rawValue:))
        guard parsed.count == strategies.count, let requestMode = PendingMaintenanceRequest.Mode(rawValue: mode),
              let pending = try? PendingMaintenanceRequest(host: vps.configuredHost, mode: requestMode, strategies: parsed) else {
            return Self.answer(400, CompanionServerActionResponse(status: "rejected", error: "That server maintenance request could not be used, so nothing was done."), row: row, outcome: "rejected")
        }
        // The route already refused a run with images and no acknowledgement.
        // This is checked again here, because this is the line that starts it.
        guard !pending.includesImages || requestMode == .scan || acknowledged else {
            return Self.answer(400, CompanionServerActionResponse(status: "rejected", error: "Removing images needs its own confirmation, so nothing was done."), row: row, outcome: "rejected")
        }
        // Past this line the request has gone to the server, so a missing result
        // means unconfirmed.  This is the one refusal `perform` can give first.
        guard !maintenance.isWorking else {
            return Self.answer(409, CompanionServerActionResponse(status: "busy", error: "Another server maintenance request is already running."), row: row, outcome: "busy")
        }
        await maintenance.perform(pending, confirmed: requestMode == .run, imageRemovalConfirmed: acknowledged)
        if requestMode == .run { vps.fetch(force: true) }
        guard let result = maintenance.result else {
            let text = maintenance.message ?? "Could not verify server maintenance."
            return Self.answer(502, CompanionServerActionResponse(status: "unknown", error: text), row: row, outcome: "unconfirmed")
        }
        let response = CompanionServerActionResponse(
            status: Self.status(forMaintenance: result.status),
            message: result.message,
            maintenance: Self.summary(result)
        )
        return Self.answer(200, response, row: row, outcome: result.status)
    }

    /// A server's `skipped` means it looked and started nothing.  Its `partial`,
    /// `cancelled` and `failed` runs may each have removed something already.
    static func status(forMaintenance status: String) -> String {
        switch status {
        case "ran", "planned": return "acted"
        case "skipped": return "noWork"
        default: return "partial"
        }
    }

    /// The fields of a process sample the phone may read.  A list of what is
    /// allowed, so the pid, start time and boot id stay here, and so does
    /// anything the server starts reporting later.
    nonisolated private static let sampleFieldsForPhone: Set<String> = [
        "name", "duration_seconds", "cpu_percent", "minor_faults", "major_faults",
        "memory_before", "memory_after", "nice", "threads", "state", "source",
    ]

    /// A sample as the phone sees it.  Nil if it cannot be read back, because
    /// passing unreadable text on could pass the identity on with it.
    nonisolated static func phoneSampleText(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let kept = object.filter { sampleFieldsForPhone.contains($0.key) }
        guard let formatted = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    /// The Mac card's rows, in the Mac card's words.
    static func summary(_ result: ServerMaintenanceResult) -> CompanionServerMaintenanceSummary {
        CompanionServerMaintenanceSummary(
            mode: result.mode,
            status: result.status,
            strategies: result.strategies.map { row in
                let title = ServerMaintenanceStrategy(rawValue: row.id)?.title ?? "Selected Strategy"
                let known = row.eligibilityIsKnown(in: result.status)
                let detail: String
                if row.id == ServerMaintenanceStrategy.packageCache.rawValue || row.id == ServerMaintenanceStrategy.rotatedLogs.rawValue {
                    detail = "\(known ? "\(row.candidateCount) eligible files" : "Eligibility not determined"); \(row.removedCount) files removed"
                } else {
                    detail = "\(known ? "\(row.candidateCount) eligible records" : "Eligibility not determined"); \(row.attemptedCount) cleanup attempts"
                }
                return CompanionServerMaintenanceRow(id: row.id, title: title, detail: detail)
            },
            removedBytesText: HogFormat.memory(UInt64(max(0, result.removedFileBytes))),
            observedChangeText: signedBytes(result.observedFreeDeltaBytes)
        )
    }

    private static func signedBytes(_ bytes: Int64) -> String {
        (bytes < 0 ? "−" : bytes > 0 ? "+" : "") + HogFormat.memory(bytes.magnitude)
    }

    // MARK: - The reading

    /// The reading every action resolves against, or the refusal when there is
    /// none to trust.  A row's identity is only as good as this reading.
    private func currentReading() -> Result<(VPSStatusSnapshot, String), Answer> {
        let host = vps.configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return .failure(Self.answer(409, CompanionServerActionResponse(status: "stale", error: "This Mac has no server set up."), row: "", outcome: "no server"))
        }
        guard let snapshot = vps.snapshot else {
            return .failure(Self.answer(409, CompanionServerActionResponse(status: "stale", error: "The Mac has no reading from the server yet, so nothing was done."), row: "", outcome: "no reading"))
        }
        guard CompanionServerStatus.readingState(generatedAt: snapshot.generatedAtDate, now: now()) == .ok else {
            return .failure(Self.answer(409, CompanionServerActionResponse(status: "stale", error: "The Mac's reading from the server is too old to act on, so nothing was done.\u{00A0} Wait for a new reading, then try again."), row: "", outcome: "stale reading"))
        }
        return .success((snapshot, host))
    }

    private static func changed() -> Answer {
        answer(409, CompanionServerActionResponse(status: "changed", error: "That row is no longer in the Mac's reading, so nothing was done.\u{00A0} Wait for the list to refresh, then try again."), row: "", outcome: "unknown row")
    }

    private static func protected(_ reason: String?, name: String) -> Answer {
        let text = reason?.isEmpty == false ? reason! : "The server does not allow that action on this row, so nothing was done."
        return answer(403, CompanionServerActionResponse(status: "protected", error: text, name: name), row: name, outcome: "protected")
    }

    private static func answer(_ status: Int, _ response: CompanionServerActionResponse, row: String, outcome: String) -> Answer {
        Answer(reply: (status, CompanionServer.encodeServerReply(response)), row: row, outcome: outcome)
    }
}
