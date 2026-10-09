import Foundation

/// Turns the Robotic Vacuum's on-disk status into the part of the phone
/// snapshot that describes it.  Pure, so it can be tested without a store, a
/// file or a clock.
enum CompanionVacuum {
    /// The most a step's reason may carry, ellipsis included.
    static let maxReasonLength = 120

    /// The most runs the phone is sent in `recentRuns`.
    static let maxRecentRuns = 20

    /// A watch tick is the five minute disk and memory check.  It is listed
    /// with the other runs but is never the "last run" the phone leads with.
    static let watchTrigger = "watch"

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
    ///
    /// `history` is newest first.  The run the phone leads with (bytes freed,
    /// when it ended, what each step did) is the newest run that is not a
    /// watch tick: the engine ticks every five minutes, so the very last run
    /// is almost always a watch tick whose only step is the disk and memory
    /// check.  `recentRuns` lists everything, watch ticks included, as the Mac
    /// does, and carries no step text, so it is not behind the opt-in.
    static func status(
        from status: RoboticVacuumStatus?,
        history: [RoboticVacuumRun],
        isRunning: Bool,
        includeSteps: Bool
    ) -> CompanionVacuumStatus? {
        let recent = recentRuns(from: history)
        guard let status else {
            guard isRunning else { return nil }
            return CompanionVacuumStatus(
                health: "unknown",
                displayHealth: "Waiting for first run",
                launchdLoaded: false,
                isRunning: true,
                recentRuns: recent
            )
        }
        let lastRun = headlineRun(status: status, history: history)
        return CompanionVacuumStatus(
            health: status.health,
            displayHealth: status.displayHealth,
            launchdLoaded: status.launchdLoaded,
            isRunning: isRunning,
            lastFullRunAt: date(status.lastRunAt?["full"]),
            nextFullRunAt: date(status.nextRunAt["full"]),
            lastRunBytesFreed: lastRun.map { max(0, $0.bytesFreed) },
            lastRunEndedAt: date(lastRun?.endedAt),
            lastRunTrigger: lastRun?.trigger,
            steps: includeSteps ? steps(from: status, lastRun: lastRun) : nil,
            recentRuns: recent
        )
    }

    /// The run the phone leads with: the newest that is not a watch tick (so
    /// janitor, full, manual and pressure runs all count), or the newest run
    /// of any kind when every run on record is a watch tick.  The status's own
    /// last run is only a fallback for a history that could not be read.
    static func headlineRun(status: RoboticVacuumStatus, history: [RoboticVacuumRun]) -> RoboticVacuumRun? {
        history.first { $0.trigger != watchTrigger } ?? history.first ?? status.lastRun
    }

    /// The newest `maxRecentRuns` runs, newest first.
    static func recentRuns(from history: [RoboticVacuumRun]) -> [CompanionVacuumRun] {
        history.prefix(maxRecentRuns).map { run in
            CompanionVacuumRun(
                runId: run.runId,
                trigger: run.trigger,
                endedAt: date(run.endedAt),
                bytesFreed: max(0, run.bytesFreed),
                exitCode: run.exitCode,
                durationSeconds: duration(from: run.startedAt, to: run.endedAt)
            )
        }
    }

    /// Whole seconds between two epoch times, never negative.  A run that
    /// never wrote an end time (0) has no duration to speak of.
    static func duration(from start: Double, to end: Double) -> Int {
        guard start > 0, end > start else { return 0 }
        return Int(min(end - start, Double(Int32.max)).rounded())
    }

    /// What the last run did.  The run's own steps, or, for a run that
    /// recorded none, what the status holds for each step.  `lastRun` is the
    /// run `headlineRun` chose, so it is a watch tick only when every run on
    /// record is one (a watch tick's steps are then the honest answer).
    static func steps(from status: RoboticVacuumStatus, lastRun: RoboticVacuumRun?) -> [CompanionVacuumStep] {
        guard let lastRun, !lastRun.steps.isEmpty else { return steps(from: status.stepLastResults) }
        return steps(from: Dictionary(lastRun.steps.map { ($0.stepId, $0) }, uniquingKeysWith: { _, newer in newer }))
    }

    /// Step results in the order the Mac lists the steps, then any step the
    /// engine knows that this build does not, by id.  The engine keeps them in
    /// a dictionary, whose order changes from one read to the next.
    static func steps(from results: [String: RoboticVacuumStepResult]) -> [CompanionVacuumStep] {
        let known = RoboticVacuumStore.catalog.map(\.id)
        let extra = results.keys.filter { !known.contains($0) }.sorted()
        return (known + extra).compactMap { id in
            guard let result = results[id] else { return nil }
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
        // Collapse ASCII whitespace only.  `.whitespacesAndNewlines` also holds
        // U+00A0, which is the gap between sentences the phone shows.
        let line = raw
            .components(separatedBy: CharacterSet(charactersIn: " \t\n\r"))
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
