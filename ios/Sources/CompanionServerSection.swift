import Foundation

/// The Server tab's sections, named and divided as the Mac's dashboard divides
/// its server view (`VPSResourceSection`).  Overview shows every reading, as
/// the Mac's Overview does.  Each other section shows one part of the same
/// snapshot, so the rows a person acts on are not buried under the rest.
///
/// Foundation only, so the Mac test bundle can pin which rows each section
/// shows.
enum CompanionServerSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case activity = "Activity"
    case storage = "Storage"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    /// CPU, memory and swap, and the paging readings beside them.
    var showsActivityReadings: Bool { self == .overview || self == .activity }
    /// The server's own processes.
    var showsProcesses: Bool { self == .overview || self == .activity }
    /// The Coolify workloads the server runs.
    var showsWorkloads: Bool { self == .overview || self == .activity }
    /// Disks, app databases, directories and the container storage readings.
    var showsStorageReadings: Bool { self == .overview || self == .storage }
    /// The tool states: the maintenance work the server runs.
    var showsTools: Bool { self == .overview || self == .maintenance }
    /// The Include in Mac Maintenance switch, and the scan and run controls.
    var showsMaintenanceControls: Bool { self == .overview || self == .maintenance }

    /// The screenshot lane's flags.  A flag picks the section whatever the
    /// phone last remembered, so a capture does not depend on stored state.
    static func screenshotOverride(arguments: [String]) -> CompanionServerSection? {
        // The Details and Controls frames are slices of the Overview, so they
        // win over a stored section as well.
        if arguments.contains("-HogHunterServerDetails") || arguments.contains("-HogHunterServerControls") { return .overview }
        if arguments.contains("-HogHunterServerActivity") { return .activity }
        if arguments.contains("-HogHunterServerStorage") { return .storage }
        if arguments.contains("-HogHunterServerMaintenance") { return .maintenance }
        // A bare server capture is the Overview, whatever an earlier run stored.
        if arguments.contains("-HogHunterServer") || arguments.contains("-HogHunterServerConfirm") { return .overview }
        return nil
    }

    /// The flags are read once: they cannot change while the app runs, and the
    /// view body would otherwise copy the process arguments on every update.
    static let screenshotSection = screenshotOverride(arguments: ProcessInfo.processInfo.arguments)

    /// The section a stored value names, Overview for anything else.
    static func stored(_ raw: String) -> CompanionServerSection {
        CompanionServerSection(rawValue: raw) ?? .overview
    }
}
