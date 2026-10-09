import Foundation

public struct ClosedRequestsAnalyticsData: Sendable {
    public let completedCount: Int
    public let returnEquipCount: Int
    public let monthlyStats: [MonthlyAnalyticsItem]
    public let monthlyChartStats: [MonthlyAnalyticsItem]
    public let latestMonthID: String?
    public let latestMonth: MonthlyAnalyticsItem?
    public let topMonth: MonthlyAnalyticsItem?
    public let maxMonthCount: Int
    public let chartMaxCount: Int
    public let requestTypeStats: [RequestTypeAnalyticsItem]
    public let maxTypeCount: Int
    public let topRequestType: RequestTypeAnalyticsItem?
    public let topDay: DailyAnalyticsItem?
    public let slaMetCount: Int
    public let slaBreachedCount: Int
    public let statusStats: [DistributionItem]
    public let assigneeStats: [DistributionItem]
    public let maxStatusCount: Int
    public let maxAssigneeCount: Int

    private let calendarDaysByMonth: [String: [MonthCalendarDay]]

    public init(records: [SimpleOneRequestRecord]) {
        self.init(archiveRecords: records.map(ClosedRequestProjection.closedRequestRecord(from:)))
    }

    private init(archiveRecords records: [ClosedRequestRecord]) {
        var completedCount = 0
        var returnEquipCount = 0
        var monthlyCounts: [String: Int] = [:]
        var monthlyDayCounts: [String: [Int: Int]] = [:]
        var typeCounts: [String: Int] = [:]
        var dailyCounts: [String: Int] = [:]
        var slaMetCount = 0
        var slaBreachedCount = 0
        var statusCounts: [String: Int] = [:]
        var assigneeCounts: [String: Int] = [:]

        for record in records {
            let status = record.status.trimmingCharacters(in: .whitespacesAndNewlines)
            statusCounts[status.isEmpty ? "Не указан" : status, default: 0] += 1
            let assignee = record.engineerName.trimmingCharacters(in: .whitespacesAndNewlines)
            assigneeCounts[assignee.isEmpty ? "Не указан" : assignee, default: 0] += 1

            let deadlineText = Self.firstAnalyticsValue(
                record.deadline,
                Self.infoValue(in: record, labels: ["Предельный срок СУТС", "Предельный срок"])
            )
            let completionText = Self.firstAnalyticsValue(
                record.completedAt,
                record.closedInMulticardAt,
                record.closedAt
            )
            if let deadline = Self.parseClosedAt(deadlineText),
               let completion = Self.parseClosedAt(completionText) {
                if completion <= deadline {
                    slaMetCount += 1
                } else {
                    slaBreachedCount += 1
                }
            }

            if Self.isReturnEquip(record.requestType) {
                returnEquipCount += 1
                continue
            }

            guard record.isCompletedWithVisit else {
                continue
            }

            completedCount += 1
            typeCounts[Self.localizedRequestType(record.requestType), default: 0] += 1

            guard let date = Self.parseClosedAt(record.closedAt) else {
                continue
            }

            let monthID = Self.monthKeyFormatter.string(from: date)
            let dayID = Self.dayKeyFormatter.string(from: date)
            let dayNumber = Self.analyticsCalendar.component(.day, from: date)

            monthlyCounts[monthID, default: 0] += 1
            dailyCounts[dayID, default: 0] += 1
            monthlyDayCounts[monthID, default: [:]][dayNumber, default: 0] += 1
        }

        let monthlyStats = monthlyCounts
            .map { key, count in
                MonthlyAnalyticsItem(
                    id: key,
                    title: Self.monthTitle(from: key),
                    shortTitle: Self.monthShortTitle(from: key),
                    count: count
                )
            }
            .sorted { lhs, rhs in
                lhs.id > rhs.id
            }

        let requestTypeStats = typeCounts
            .map { key, count in
                RequestTypeAnalyticsItem(title: key, count: count)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        let topDay = dailyCounts
            .map { key, count in
                DailyAnalyticsItem(id: key, title: Self.dayTitle(from: key), count: count)
            }
            .max { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count
                }
                return lhs.id < rhs.id
            }

        let statusStats = Self.distributionItems(statusCounts)
        let assigneeStats = Self.distributionItems(assigneeCounts)

        var calendarDaysByMonth: [String: [MonthCalendarDay]] = [:]
        for item in monthlyStats {
            calendarDaysByMonth[item.id] = Self.makeCalendarDays(
                monthID: item.id,
                dayCounts: monthlyDayCounts[item.id] ?? [:]
            )
        }

        self.completedCount = completedCount
        self.returnEquipCount = returnEquipCount
        self.monthlyStats = monthlyStats
        self.monthlyChartStats = Array(monthlyStats.reversed())
        self.latestMonthID = monthlyStats.first?.id
        self.latestMonth = monthlyStats.first
        self.topMonth = monthlyStats.max { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.id < rhs.id
        }
        self.maxMonthCount = monthlyStats.map(\.count).max() ?? 0
        self.chartMaxCount = Array(monthlyStats.prefix(6)).map(\.count).max() ?? 0
        self.requestTypeStats = requestTypeStats
        self.maxTypeCount = requestTypeStats.map(\.count).max() ?? 0
        self.topRequestType = requestTypeStats.first
        self.topDay = topDay
        self.calendarDaysByMonth = calendarDaysByMonth
        self.slaMetCount = slaMetCount
        self.slaBreachedCount = slaBreachedCount
        self.statusStats = statusStats
        self.assigneeStats = assigneeStats
        self.maxStatusCount = statusStats.map(\.count).max() ?? 0
        self.maxAssigneeCount = assigneeStats.map(\.count).max() ?? 0
    }

    public func monthCalendarDays(for monthID: String) -> [MonthCalendarDay] {
        calendarDaysByMonth[monthID] ?? []
    }

    public func monthlyItem(id: String) -> MonthlyAnalyticsItem? {
        monthlyStats.first(where: { $0.id == id })
    }

    public struct MonthlyAnalyticsItem: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let shortTitle: String
        public let count: Int
    }

    public struct RequestTypeAnalyticsItem: Identifiable, Sendable {
        public let title: String
        public let count: Int

        public var id: String { title }
    }

    public struct DailyAnalyticsItem: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let count: Int
    }

    public struct DistributionItem: Identifiable, Sendable {
        public let title: String
        public let count: Int

        public var id: String { title }
    }

    public struct MonthCalendarDay: Identifiable, Sendable {
        public let id: String
        public let dayNumber: Int?
        public let count: Int
        public let isPlaceholder: Bool

        static func placeholder(id: String) -> MonthCalendarDay {
            MonthCalendarDay(id: id, dayNumber: nil, count: 0, isPlaceholder: true)
        }
    }

    private static func isReturnEquip(_ raw: String) -> Bool {
        let type = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        return type == "returnequip"
            || type == "return_equip"
            || type.contains("возврат то")
            || type.contains("возврат")
    }

    nonisolated private static func distributionItems(_ counts: [String: Int]) -> [DistributionItem] {
        counts
            .map { DistributionItem(title: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    nonisolated private static func infoValue(in record: ClosedRequestRecord, labels: [String]) -> String? {
        let normalizedLabels = labels.map(Self.normalizedLabel)
        return record.infoFields.first {
            normalizedLabels.contains(Self.normalizedLabel($0.key))
        }?.value
    }

    nonisolated private static func firstAnalyticsValue(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    nonisolated private static func normalizedLabel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }

    private static func localizedRequestType(_ raw: String) -> String {
        if isReturnEquip(raw) {
            return "Возврат ТО"
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "install":
            return "Установка"
        case "dismounting":
            return "Демонтаж"
        case "serviceStd":
            return "Сервисная"
        case "replacement":
            return "Замена"
        default:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Не указан" : trimmed
        }
    }

    private static func parseClosedAt(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let serial = Double(trimmed), serial.isFinite, abs(serial) < 10_000_000 {
            let excelBaseDate = Date(timeIntervalSince1970: -2209161600)
            return excelBaseDate.addingTimeInterval(serial * 86_400)
        }

        for formatter in closedAtParsingFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private static func makeCalendarDays(monthID: String, dayCounts: [Int: Int]) -> [MonthCalendarDay] {
        guard
            let monthDate = monthKeyFormatter.date(from: monthID),
            let monthInterval = analyticsCalendar.dateInterval(of: .month, for: monthDate),
            let daysRange = analyticsCalendar.range(of: .day, in: .month, for: monthDate)
        else {
            return []
        }

        let firstWeekday = analyticsCalendar.component(.weekday, from: monthInterval.start)
        let leadingEmptyDays = (firstWeekday - analyticsCalendar.firstWeekday + 7) % 7

        var days: [MonthCalendarDay] = (0..<leadingEmptyDays).map { index in
            MonthCalendarDay.placeholder(id: "placeholder-\(monthID)-\(index)")
        }

        days += daysRange.map { day in
            MonthCalendarDay(
                id: "\(monthID)-\(day)",
                dayNumber: day,
                count: dayCounts[day] ?? 0,
                isPlaceholder: false
            )
        }

        let trailingEmptyDays = (7 - (days.count % 7)) % 7
        days += (0..<trailingEmptyDays).map { index in
            MonthCalendarDay.placeholder(id: "tail-\(monthID)-\(index)")
        }

        return days
    }

    private static func monthTitle(from key: String) -> String {
        guard let date = monthKeyFormatter.date(from: key) else {
            return key
        }
        return monthTitleFormatter.string(from: date)
    }

    private static func monthShortTitle(from key: String) -> String {
        guard let date = monthKeyFormatter.date(from: key) else {
            return key
        }
        return monthShortTitleFormatter.string(from: date).capitalized
    }

    private static func dayTitle(from key: String) -> String {
        guard let date = dayKeyFormatter.date(from: key) else {
            return key
        }
        return dayTitleFormatter.string(from: date)
    }

    private static let closedAtParsingFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm",
            "MM.dd.yyyy HH:mm:ss",
            "MM.dd.yyyy HH:mm",
            "MM.dd.yyyy H:mm"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let monthShortTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "LLL"
        return formatter
    }()

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let analyticsCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2
        return calendar
    }()
}
