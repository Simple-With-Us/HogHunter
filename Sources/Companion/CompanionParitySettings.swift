import Foundation

/// Checks a Maintain settings change from the phone before the Mac applies
/// any of it.  The route receives bytes, not sliders, so this is the only gate.
/// A change is applied whole or not at all: one bad field rejects the request.
///
/// The bounds are `CompanionMaintainLimits`, the same ones the Mac's
/// Maintenance settings use.
enum CompanionMaintainSettingsValidator {
    struct Validated: Equatable {
        /// Built-in step ids only.
        var stepEnabled: [String: Bool]
        var lowFreeGiB: Double?
        var worktreeRetireMinDays: Int?
        var pm2LogsCapMB: Int?
    }

    /// The built-in step ids.  A custom script is not among them, which is
    /// the whole rule that keeps the phone from enabling one.
    static var builtInStepIds: Set<String> { Set(MaintainStore.catalog.map(\.id)) }

    static func validate(
        _ request: CompanionMaintainSettingsRequest,
        builtInIds: Set<String> = builtInStepIds
    ) -> Result<Validated, CompanionSettingsRejection> {
        var validated = Validated(stepEnabled: [:])
        for (id, enabled) in request.stepEnabled ?? [:] {
            guard builtInIds.contains(id) else {
                return .failure(.init("That is not one of Hog Hunter's built-in steps.\u{00A0} Custom scripts are turned on or off at the Mac only."))
            }
            if id == CompanionMaintainLimits.remoteServerStepId, enabled, request.acknowledgeRemoteServer != true {
                return .failure(.init("Turning on server maintenance needs a confirmation.\u{00A0} It runs maintenance on your remote server every time the Mac runs the Maintain."))
            }
            validated.stepEnabled[id] = enabled
        }
        if let gib = request.lowFreeGiB {
            let range = CompanionMaintainLimits.lowFreeGiBRange
            let step = CompanionMaintainLimits.lowFreeGiBStep
            let steps = (gib - range.lowerBound) / step
            guard gib.isFinite, range.contains(gib), steps == steps.rounded() else {
                return .failure(.init("The disk threshold must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)) GB, in steps of \(Int(step))."))
            }
            validated.lowFreeGiB = gib
        }
        if let days = request.worktreeRetireMinDays {
            let range = CompanionMaintainLimits.worktreeRetireDaysRange
            guard range.contains(days) else {
                return .failure(.init("Worktree retention must be \(range.lowerBound) to \(range.upperBound) whole days."))
            }
            validated.worktreeRetireMinDays = days
        }
        if let cap = request.pm2LogsCapMB {
            let range = CompanionMaintainLimits.pm2LogsCapMBRange
            let step = CompanionMaintainLimits.pm2LogsCapMBStep
            guard range.contains(cap), (cap - range.lowerBound) % step == 0 else {
                return .failure(.init("The PM2 log cap must be between \(range.lowerBound) and \(range.upperBound) MB, in steps of \(step)."))
            }
            validated.pm2LogsCapMB = cap
        }
        return .success(validated)
    }
}

/// Checks a cleaner settings change from the phone.  The only field is the
/// temp file minimum, and it can never go below the Mac's own lowest choice.
enum CompanionCleanSettingsValidator {
    struct Validated: Equatable {
        var tempFileMinimumHours: Double
    }

    static func validate(_ request: CompanionCleanSettingsRequest) -> Result<Validated, CompanionSettingsRejection> {
        guard let hours = request.tempFileMinimumHours else {
            return .failure(.init("The cleaner settings change was empty."))
        }
        guard TempFileSafetyPolicy.isValid(hours) else {
            let range = CompanionCleanLimits.tempFileHoursRange
            return .failure(.init("The temp file minimum must be \(Int(range.lowerBound)) to \(range.upperBound.formatted(.number.grouping(.automatic))) whole hours."))
        }
        return .success(Validated(tempFileMinimumHours: hours))
    }
}

extension CompanionMaintain {
    /// The built-in steps in the Mac's order, each with its state.  Only the
    /// steps the Mac shows are listed: the remote server step stays out until
    /// a host is set, as it does in the Mac's Maintenance settings.
    static func stepSettings(visible: [MaintainStepCatalogEntry], isEnabled: (String) -> Bool) -> [CompanionMaintainStepSetting] {
        visible.map { entry in
            CompanionMaintainStepSetting(
                stepId: entry.id,
                title: entry.title,
                isEnabled: isEnabled(entry.id),
                isRemoteServer: entry.id == CompanionMaintainLimits.remoteServerStepId
            )
        }
    }

    /// Custom scripts by name and state.  The path, the argument list and the
    /// owner stay on the Mac.
    static func scripts(_ entries: [MaintainScriptEntry], isEnabled: (String) -> Bool) -> [CompanionMaintainScript] {
        entries.map { entry in
            CompanionMaintainScript(
                name: entry.displayName,
                isEnabled: isEnabled(entry.id),
                mode: entry.mode.lowercased(),
                scope: entry.scope.lowercased()
            )
        }
    }
}
