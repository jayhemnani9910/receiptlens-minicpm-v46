import Foundation

enum HistoryBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case previous7 = "Previous 7 Days"
    case earlier = "Earlier"
}

enum HistorySectioning {
    static func bucket(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HistoryBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let startOfToday = calendar.startOfDay(for: now)
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
           date >= sevenDaysAgo {
            return .previous7
        }
        return .earlier
    }

    /// Newest first within each bucket; buckets in fixed display order;
    /// empty buckets omitted.
    static func grouped(
        _ scans: [ReceiptScan],
        now: Date = Date()
    ) -> [(bucket: HistoryBucket, scans: [ReceiptScan])] {
        let sorted = scans.sorted { $0.createdAt > $1.createdAt }
        var map: [HistoryBucket: [ReceiptScan]] = [:]
        for scan in sorted {
            map[bucket(for: scan.createdAt, now: now), default: []].append(scan)
        }
        return HistoryBucket.allCases.compactMap { bucket in
            guard let scans = map[bucket], !scans.isEmpty else { return nil }
            return (bucket, scans)
        }
    }

    /// Case-insensitive match on output text or mode name. Blank query passes all.
    static func filter(_ scans: [ReceiptScan], query: String) -> [ReceiptScan] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return scans }
        return scans.filter {
            $0.output.lowercased().contains(trimmed)
                || $0.mode.rawValue.lowercased().contains(trimmed)
        }
    }
}
