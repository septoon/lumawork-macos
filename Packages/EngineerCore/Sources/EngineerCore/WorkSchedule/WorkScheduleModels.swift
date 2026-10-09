import Foundation

public struct WorkScheduleJournal: Codable, Hashable, Identifiable, Sendable {
    public let sysID: String
    public let cityID: String
    public let cityName: String
    public let year: Int
    public let month: Int

    public var id: String { sysID }
}

public struct WorkScheduleDayValue: Codable, Hashable, Identifiable, Sendable {
    public let day: Int
    public let hours: Double
    public let isActive: Bool

    public var id: Int { day }
}

public struct WorkScheduleEmployee: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let login: String
    public let totalHours: Double
    public let dayValues: [WorkScheduleDayValue]

    public func value(for day: Int) -> WorkScheduleDayValue? {
        dayValues.first { $0.day == day }
    }
}

public struct WorkScheduleDailyTotal: Codable, Hashable, Identifiable, Sendable {
    public let day: Int
    public let count: Int

    public var id: Int { day }
}

public struct WorkScheduleAuditInfo: Codable, Hashable, Sendable {
    public let createdBy: String?
    public let createdAt: Date?
    public let updatedBy: String?
    public let updatedAt: Date?

    public var hasContent: Bool {
        createdBy != nil || createdAt != nil || updatedBy != nil || updatedAt != nil
    }
}

public struct WorkSchedule: Codable, Hashable, Sendable {
    public let journal: WorkScheduleJournal
    public let daysInMonth: Int
    public let employees: [WorkScheduleEmployee]
    public let dailyTotals: [WorkScheduleDailyTotal]
    public let auditInfo: WorkScheduleAuditInfo?
}

public enum WorkScheduleCachePolicy {
    public static func canReuse(_ schedule: WorkSchedule, forceRefresh: Bool) -> Bool {
        !forceRefresh && schedule.auditInfo?.hasContent == true
    }
}

public enum WorkScheduleParsingError: Error, Equatable {
    case missingJournalItems
    case missingScheduleData
    case missingWidgetInstanceID
}
