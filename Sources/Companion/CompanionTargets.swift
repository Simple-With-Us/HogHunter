import Foundation

/// An app or process row the Mac last showed the phone, with the exact
/// processes behind it.  Each member carries the start time it was sampled
/// with, which is what lets a later action prove the pid still belongs to the
/// same process.
struct CompanionTarget: Equatable, Sendable {
    var rowId: String
    var name: String
    var members: [ProcessKey]
}

/// Maps what a phone request points at to the live processes behind it.
enum CompanionTargets {
    /// Live rows only.  A history row has no members, so there is nothing to act on.
    static func index(_ rows: [HogRow]) -> [String: CompanionTarget] {
        var targets: [String: CompanionTarget] = [:]
        targets.reserveCapacity(rows.count)
        for row in rows where !row.keys.isEmpty {
            targets[row.id] = CompanionTarget(rowId: row.id, name: row.name, members: row.keys)
        }
        return targets
    }

    /// The target a request points at, or nil when the Mac no longer shows it.
    ///
    /// A row id acts on the whole row: every process of an app group.  A bare
    /// pid, from an older phone, acts on that one process only, and only if
    /// the last snapshot listed it, because that is where its start time comes
    /// from.  A pid the Mac never listed is refused.
    static func resolve(_ request: CompanionProcessRequest, in targets: [String: CompanionTarget]) -> CompanionTarget? {
        if let rowId = request.rowId {
            return targets[rowId]
        }
        guard let pid = request.pid else { return nil }
        for target in targets.values {
            if let member = target.members.first(where: { $0.pid == pid }) {
                return CompanionTarget(rowId: target.rowId, name: target.name, members: [member])
            }
        }
        return nil
    }

    /// Why a request resolved to nothing, in words the phone shows.
    static func unresolvedMessage(for request: CompanionProcessRequest) -> String {
        if request.rowId?.hasPrefix("h-") == true {
            return "That entry is only in history.\u{00A0} Switch the Mac to Now to act on a live process."
        }
        return "That app or process is no longer where the phone last saw it.\u{00A0} Wait for the list to refresh, then try again."
    }
}
