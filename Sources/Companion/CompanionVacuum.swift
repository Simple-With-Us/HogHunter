import Foundation

/// Turns the Robotic Vacuum's on-disk status into the part of the phone
/// snapshot that describes it.  Pure, so it can be tested without a store, a
/// file or a clock.
enum CompanionVacuum {
    /// The most a step's reason may carry, ellipsis included.
    static let maxReasonLength = 120

    /// The status for the phone, or nil when there is nothing to say.
    ///
    /// Disclosure: the coarse fields (health, schedule, last run) are present
    /// whenever a status exists.  `steps` is present only when `includeSteps`
    /// is true, which the host sets from the opt-in: a step's reason can name
    /// a lane folder or a server, and the snapshot is readable with the
    /// shared pairing code from anywhere.
    ///
    /// A run that is going before the engine has written any status (the very
    /// first run) still gets a minimal status, so the phone shows it running.
    static func status(
        from status: RoboticVacuumStatus?,
        history: [RoboticVacuumRun],
        isRunning: Bool,
        includeSteps: Bool
    ) -> CompanionVacuumStatus? {
        guard let status else {
            guard isRunning else { return nil }
            return CompanionVacuumStatus(
                health: "unknown",
                displayHealth: "Waiting for first run",
                launchdLoaded: false,
                isRunning: true
            )
        }
        // `history` is newest first.  The status carries the last run itself,
        // so the history is only a fallback.
        let lastRun = status.lastRun ?? history.first
        return CompanionVacuumStatus(
            health: status.health,
            displayHealth: status.displayHealth,
            launchdLoaded: status.launchdLoaded,
            isRunning: isRunning,
            lastFullRunAt: date(status.lastRunAt?["full"]),
            nextFullRunAt: date(status.nextRunAt["full"]),
            lastRunBytesFreed: lastRun.map { max(0, $0.bytesFreed) },
            lastRunEndedAt: date(lastRun?.endedAt),
            steps: includeSteps ? steps(from: status) : nil
        )
    }

    /// Step results in the order the Mac lists the steps, then any step the
    /// engine knows that this build does not, by id.  The status keeps them in
    /// a dictionary, whose order changes from one read to the next.
    static func steps(from status: RoboticVacuumStatus) -> [CompanionVacuumStep] {
        let known = RoboticVacuumStore.catalog.map(\.id)
        let extra = status.stepLastResults.keys.filter { !known.contains($0) }.sorted()
        return (known + extra).compactMap { id in
            guard let result = status.stepLastResults[id] else { return nil }
            let title = result.title.isEmpty
                ? (RoboticVacuumStore.catalog.first { $0.id == id }?.title ?? id)
                : result.title
            return CompanionVacuumStep(
                stepId: id,
                title: title,
                statusLabel: result.statusLabel,
                reason: cappedReason(result.reason),
                bytesFreed: max(0, result.bytesFreed)
            )
        }
    }

    /// One line of at most `maxReasonLength` characters, ellipsis included.
    static func cappedReason(_ raw: String) -> String {
        let line = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard line.count > maxReasonLength else { return line }
        return String(line.prefix(maxReasonLength - 1)) + "…"
    }

    /// The engine writes epoch seconds and uses 0 or less for "never".
    static func date(_ epoch: Double?) -> Date? {
        guard let epoch, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
