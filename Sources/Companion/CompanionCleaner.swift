import Foundation

/// A scan the Mac is holding for the phone.
///
/// `CleanItem.id` is the item's filesystem path, so the phone is never allowed
/// to send one.  The report gives the phone short references ("3.12" is the
/// thirteenth item of the fourth category) and the Mac resolves a reference
/// against its own copy of the scan, here.  A reference the scan does not
/// hold, or a scan that is not the current one, cleans nothing.
struct RemoteCleanScan: Sendable {
    var id: String
    var tier: CleanTier
    var scannedAt: Date
    var categories: [CompanionCleanCategory]
    /// Reference to the real item.
    var refs: [String: CleanItem]
    var totalBytes: UInt64
    var totalItems: Int

    /// The references the Mac's own cleaner would start with ticked.
    var defaultRefs: Set<String> {
        Set(categories.flatMap { $0.items }.filter(\.isSelected).map(\.id))
    }
}

/// Turns a scan into the phone's report, and a phone's request into the items
/// to clean.  Pure, so every rule is a unit test.
enum CompanionCleanerReport {
    /// Thinning APFS local snapshots stays a Mac-only choice.  `DiskCleaner`
    /// thins every local snapshot in one call whichever row is ticked, and it
    /// does so before the safety snapshot is taken, so it removes the rollback
    /// point an earlier clean left and the confirmation ("a snapshot is created
    /// first, and if that fails nothing is deleted") would not be true.  The
    /// phone neither lists nor accepts them.
    static func phoneMayClean(_ category: CleanCategory) -> Bool {
        category != .apfsSnapshots
    }

    /// The most items one category lists.  The rest are counted, not sent.
    static let itemsPerCategory = 100

    /// How long a scan stays cleanable.  Files change; an old scan is a guess.
    static let scanLifetime: TimeInterval = 30 * 60

    /// Largest first, capped, with a reference per item.  An item starts
    /// ticked when the Mac's cleaner would tick it: its category is selected
    /// by default and the item itself is.
    static func build(from report: CleanScanReport, id: String, now: Date = Date()) -> RemoteCleanScan {
        var categories: [CompanionCleanCategory] = []
        var refs: [String: CleanItem] = [:]
        let included = report.categories.filter { phoneMayClean($0.category) }
        for (categoryIndex, categoryReport) in included.enumerated() {
            let ordered = categoryReport.items.sorted { $0.bytes > $1.bytes }.prefix(itemsPerCategory)
            var items: [CompanionCleanItem] = []
            for (itemIndex, item) in ordered.enumerated() {
                let ref = "\(categoryIndex).\(itemIndex)"
                refs[ref] = item
                items.append(CompanionCleanItem(
                    id: ref,
                    title: item.title,
                    subtitle: item.subtitle,
                    bytes: item.bytes,
                    sizeText: HogFormat.memory(item.bytes),
                    fileCount: item.fileCount,
                    detail: item.detail,
                    isSelected: categoryReport.category.defaultSelected && item.isSelected
                ))
            }
            categories.append(CompanionCleanCategory(
                id: categoryReport.category.rawValue,
                title: categoryReport.category.title,
                description: categoryReport.category.description,
                icon: categoryReport.category.icon,
                isExtremeOnly: categoryReport.category.isExtremeOnly,
                totalBytes: categoryReport.totalBytes,
                totalText: HogFormat.memory(categoryReport.totalBytes),
                itemCount: categoryReport.itemCount,
                items: items
            ))
        }
        return RemoteCleanScan(
            id: id,
            tier: report.tier,
            scannedAt: report.scannedAt,
            categories: categories,
            refs: refs,
            totalBytes: included.reduce(0) { $0 + $1.totalBytes },
            totalItems: included.reduce(0) { $0 + $1.itemCount }
        )
    }

    /// The items the Mac's own cleaner would start with ticked, from a fresh scan.
    static func defaultSelection(of report: CleanScanReport) -> [CleanItem] {
        report.categories.flatMap { categoryReport in
            categoryReport.category.defaultSelected && phoneMayClean(categoryReport.category) ? categoryReport.items.filter(\.isSelected) : []
        }
    }

    /// A refusal, with the status and the sentence the phone shows.
    struct Refusal: Error, Equatable {
        var status: Int
        var message: String

        var reply: (status: Int, body: Data) {
            let body = (try? JSONSerialization.data(withJSONObject: ["status": "rejected", "error": message])) ?? Data()
            return (status, body)
        }
    }

    struct Plan: Equatable {
        var tier: CleanTier
        var items: [CleanItem]
    }

    static let extremeNeedsAcknowledgement = "Extreme Clean needs the notice acknowledged on the iPhone first."

    /// Resolves a clean request against the scan the Mac holds, or refuses it.
    static func plan(for request: CompanionCleanRequest, scan: RemoteCleanScan?, now: Date = Date()) -> Result<Plan, Refusal> {
        guard let scan else {
            return .failure(Refusal(status: 409, message: "The Mac has no scan to clean from.\u{00A0} Scan first."))
        }
        let stale = Refusal(status: 409, message: "That scan is out of date.\u{00A0} Scan again, then choose what to clean.")
        guard let scanId = request.scanId, scanId == scan.id else { return .failure(stale) }
        guard now.timeIntervalSince(scan.scannedAt) <= scanLifetime else { return .failure(stale) }

        let tier: CleanTier
        if let named = request.tier {
            guard let parsed = CleanTier(rawValue: named) else {
                return .failure(Refusal(status: 400, message: "That clean level is not one the Mac offers."))
            }
            tier = parsed
        } else {
            tier = scan.tier
        }
        guard tier == scan.tier else { return .failure(stale) }
        if tier == .extreme, request.acknowledgedExtreme != true {
            return .failure(Refusal(status: 400, message: extremeNeedsAcknowledgement))
        }

        guard let references = request.items, !references.isEmpty else {
            return .failure(Refusal(status: 400, message: "Nothing is selected."))
        }
        var chosen: [String: CleanItem] = [:]
        for reference in references {
            guard let item = scan.refs[reference], phoneMayClean(item.category) else {
                return .failure(Refusal(status: 400, message: "The iPhone named an item this scan does not have.\u{00A0} Scan again."))
            }
            chosen[reference] = item
        }
        // The Mac's own order, so a clean runs the same way whoever started it.
        let ordered = scan.categories.flatMap { $0.items }.compactMap { chosen[$0.id] }
        return .success(Plan(tier: tier, items: ordered))
    }

    /// Whether a scan request may start: Extreme needs the acknowledgement.
    static func validate(_ request: CompanionCleanScanRequest) -> Result<CleanTier, Refusal> {
        guard let tier = CleanTier(rawValue: request.tier) else {
            return .failure(Refusal(status: 400, message: "That clean level is not one the Mac offers."))
        }
        if tier == .extreme, !request.acknowledgedExtreme {
            return .failure(Refusal(status: 400, message: extremeNeedsAcknowledgement))
        }
        return .success(tier)
    }

    /// The phone's view of one finished cleanup.
    static func record(_ record: CleanupHistoryRecord) -> CompanionCleanupRecord {
        CompanionCleanupRecord(
            id: "\(Int(record.cleanedAt.timeIntervalSince1970 * 1000))-\(record.bytesReclaimed)",
            cleanedAt: record.cleanedAt,
            bytesReclaimed: record.bytesReclaimed,
            sizeText: HogFormat.memory(record.bytesReclaimed),
            itemsRemoved: record.itemsRemoved,
            tier: record.tier.rawValue,
            tierTitle: record.tier.title,
            categoryTitles: record.categoryIds.compactMap { CleanCategory(rawValue: $0)?.title },
            itemTitles: Array(record.itemTitles.prefix(5)),
            snapshotName: record.snapshotName,
            source: record.source
        )
    }
}
