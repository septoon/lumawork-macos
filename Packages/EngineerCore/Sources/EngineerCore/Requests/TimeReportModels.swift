import Foundation

public struct TimeReportEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String {
        stableID
    }

    public var activity: String
    public var simpleOneRecordID: String? = nil
    public var period: String
    public var createdAt: Date
    public var createdAtRaw: String
    public var workDate: Date?
    public var workDateRaw: String?
    public var workMinutes: Int
    public var travelMinutes: Int
    public var overtimeMinutes: Int
    public var notes: String
    public var nonWorkCosts: String
    public var isOvertime: Bool
    public var executor: String

    public var effectiveWorkDate: Date {
        workDate ?? createdAt
    }

    public var stableID: String {
        [
            activity,
            String(Int(createdAt.timeIntervalSince1970)),
            executor
        ]
        .joined(separator: "|")
    }
}
