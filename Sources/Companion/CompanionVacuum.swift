import Foundation

/// Turns the Robotic Vacuum's on-disk status into the part of the phone
/// snapshot that describes it.  Pure, so it can be tested without a store, a
/// file or a clock.
enum CompanionVacuum {
    /// The most a step's reason may carry, ellipsis included.
    static let maxReasonLength = 120

    /// The most cleaning runs the Mac lists and the phone is sent in `recentRuns`.
    static let maxRecentRuns = 20

    /// A watch tick is the five minute disk and memory check.  It is not a
    /// cleaning run: it is summed up in `watch` instead of listed, and it is
    /// never the "last run" the phone leads with.
    static let watchTrigger = CompanionVacuumRun.watchTrigger

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
    /// when it ended, what each step did) is the newest cleaning run: the
    /// engine ticks every five minutes, so the very last run is almost always
    /// a watch tick whose only step is the disk and memory check.  `recentRuns`
    /// lists the cleaning runs only, as the Mac does, and `watch` sums up the
    /// ticks.  Neither carries step text, so neither is behind the opt-in.
    ///
    /// `now` and `calendar` say what "today" is for the watch count.
    static func status(
        from status: RoboticVacuumStatus?,
        history: [RoboticVacuumRun],
        isRunning: Bool,
        includeSteps: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CompanionVacuumStatus? {
        let recent = recentRuns(from: history)
        let watchSummary = watch(from: history, now: now, calendar: calendar)
        guard let status else {
            guard isRunning else { return nil }
            return CompanionVacuumStatus(
                health: "unknown",
                displayHealth: "Waiting for first run",
                launchdLoaded: false,
                isRunning: true,
                recentRuns: recent,
                watch: watchSummary
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
            lastRunTrigger: lastRun?.displayTrigger,
            steps: includeSteps ? steps(from: status, lastRun: lastRun) : nil,
            recentRuns: recent,
            watch: watchSummary
        )
    }

    /// The run the phone leads with: the newest cleaning run (so janitor,
    /// full, manual and pressure runs all count, and so does a watch tick that
    /// went on to clean), or the newest run of any kind when every run on
    /// record is a quiet tick.  The status's own last run is only a fallback
    /// for a history that could not be read.
    static func headlineRun(status: RoboticVacuumStatus, history: [RoboticVacuumRun]) -> RoboticVacuumRun? {
        history.first { $0.isCleaningRun } ?? history.first ?? status.lastRun
    }

    /// The newest `maxRecentRuns` cleaning runs, newest first.  The Mac's list
    /// and the phone's payload both come from here, so they list the same runs
    /// and mark them the same way.
    ///
    /// A quiet watch tick is left out.  One that found the disk or memory in
    /// trouble and cleaned is a run like any other and stays in, listed as
    /// "pressure" because that is what its steps ran as.
    static func recentRuns(from history: [RoboticVacuumRun]) -> [CompanionVacuumRun] {
        history.filter(\.isCleaningRun).prefix(maxRecentRuns).map { run in
            CompanionVacuumRun(
                runId: run.runId,
                trigger: run.displayTrigger,
                endedAt: date(run.endedAt),
                bytesFreed: max(0, run.bytesFreed),
                exitCode: run.exitCode,
                durationSeconds: duration(from: run.startedAt, to: run.endedAt),
                outcome: run.resolvedOutcome
            )
        }
    }

    /// When the last check ran and how many ran today, or nil with no check on
    /// record.  "Today" starts at the calendar's midnight, and the calendar's
    /// time zone travels with the answer so the phone reads it the same way.
    ///
    /// The engine keeps a bounded history, so it may not reach back to
    /// midnight (a long day, or an engine that keeps fewer runs).  Then the
    /// count would be low and "today" a false word, so `countedSince` says
    /// where the history starts and the line says "since" instead.
    static func watch(from history: [RoboticVacuumRun], now: Date, calendar: Calendar = .current) -> CompanionVacuumWatch? {
        let checkTimes = history.filter(\.isCheck).compactMap(\.finishedOrStartedAt)
        guard let last = checkTimes.max() else { return nil }
        let midnight = calendar.startOfDay(for: now)
        let oldest = history.compactMap { run -> Date? in
            let epoch = run.startedAt > 0 ? run.startedAt : run.endedAt
            return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        }.min()
        return CompanionVacuumWatch(
            lastCheckAt: last,
            checksToday: checkTimes.filter { $0 >= midnight }.count,
            countedSince: oldest.flatMap { $0 > midnight ? $0 : nil },
            timeZoneIdentifier: calendar.timeZone.identifier
        )
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
