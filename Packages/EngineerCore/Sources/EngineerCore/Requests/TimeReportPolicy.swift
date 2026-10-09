import Foundation

public enum TimeReportPolicy {
    public static func merge(existing: [TimeReportEntry], incoming: [TimeReportEntry]) -> [TimeReportEntry] {
        var entries = Dictionary(existing.map { ($0.stableID, $0) }, uniquingKeysWith: { _, last in last })
        for entry in incoming { entries[entry.stableID] = entry }
        let values = Array(entries.values)
        func isREQ(_ entry: TimeReportEntry) -> Bool { entry.activity.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: Locale(identifier: "en_US_POSIX")).hasPrefix("REQ") }
        func minute(_ entry: TimeReportEntry) -> Int64 { Int64(floor(entry.effectiveWorkDate.timeIntervalSince1970 / 60)) }
        let nonREQMinutes = Set(values.filter { !isREQ($0) }.map(minute))
        return values.filter { !isREQ($0) || !nonREQMinutes.contains(minute($0)) }.sorted {
            if $0.effectiveWorkDate != $1.effectiveWorkDate { return $0.effectiveWorkDate > $1.effectiveWorkDate }
            return $0.activity.localizedStandardCompare($1.activity) == .orderedAscending
        }
    }
    public static func duration(_ minutes: Int) -> String { "\(minutes / 60) ч. \(minutes % 60) мин." }
}
