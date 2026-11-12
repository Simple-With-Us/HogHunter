import Foundation

/// One mean per wall-clock minute, independent of the sampler's refresh interval.
struct CpuMinuteHistory {
    struct Bucket: Equatable {
        let minute: Int
        var total: Double
        var count: Int
        var average: Double { total / Double(count) }
    }

    private(set) var buckets: [Bucket] = []
    static let count = 30

    mutating func record(percent: Double, at date: Date) {
        guard percent.isFinite, date.timeIntervalSince1970.isFinite else { return }
        let minute = Int(floor(date.timeIntervalSince1970 / 60))
        guard buckets.last.map({ minute >= $0.minute }) ?? true else { return }
        let value = min(100, max(0, percent))
        if buckets.last?.minute == minute {
            buckets[buckets.count - 1].total += value
            buckets[buckets.count - 1].count += 1
        } else {
            buckets.append(Bucket(minute: minute, total: value, count: 1))
        }
        buckets.removeAll { $0.minute < minute - Self.count + 1 }
    }

    func bars(at date: Date) -> [Double?] {
        let minute = Int(floor(date.timeIntervalSince1970 / 60))
        let values = Dictionary(uniqueKeysWithValues: buckets.map { ($0.minute, $0.average) })
        return ((minute - Self.count + 1)...minute).map { values[$0] }
    }
}
