import Foundation

public enum SimpleOneWorkScheduleParser {
    public static func journals(from response: [String: Any]) throws -> [WorkScheduleJournal] {
        guard let items = dictionary(response["data"])?["items"] as? [Any] else {
            throw WorkScheduleParsingError.missingJournalItems
        }

        return items.compactMap { rawItem in
            guard let item = dictionary(rawItem),
                  let sysID = fieldDatabaseValue(item["sys_id"]),
                  let cityID = fieldDatabaseValue(item["city"]),
                  let cityName = fieldDisplayValue(item["city"]),
                  let yearText = fieldDatabaseValue(item["year"]),
                  let year = Int(yearText),
                  let monthText = fieldDatabaseValue(item["month"]),
                  let month = monthNumber(monthText) ?? monthNumber(fieldDisplayValue(item["month"]))
            else {
                return nil
            }

            return WorkScheduleJournal(
                sysID: sysID,
                cityID: cityID,
                cityName: cityName,
                year: year,
                month: month
            )
        }
    }

    public static func schedule(
        from response: [String: Any],
        journal: WorkScheduleJournal,
        auditInfo: WorkScheduleAuditInfo? = nil
    ) throws -> WorkSchedule {
        guard let rawScheduleData = recursivelyFindValue(for: "scheduleData", in: response),
              let scheduleData = scheduleDictionary(rawScheduleData)
        else {
            throw WorkScheduleParsingError.missingScheduleData
        }

        let parsedDaysInMonth = intValue(recursivelyFindValue(for: "daysInMonth", in: response))
        let daysInMonth = parsedDaysInMonth.flatMap { (1...31).contains($0) ? $0 : nil }
            ?? calendarDaysInMonth(year: journal.year, month: journal.month)

        let employees = scheduleData.compactMap { displayName, rawEmployee -> WorkScheduleEmployee? in
            guard !isAggregateRow(displayName),
                  let employee = dictionary(rawEmployee) else { return nil }
            let identity = employeeIdentity(from: displayName)
            let id = stringValue(employee["employeeSysId"])
                ?? stringValue(employee["employee_sys_id"])
                ?? identity.login
                ?? identity.name

            let dayValues = (1...daysInMonth).compactMap { day -> WorkScheduleDayValue? in
                guard let dayData = dictionary(employee[String(day)]),
                      let hours = doubleValue(dayData["hoursWork"])
                else {
                    return nil
                }
                return WorkScheduleDayValue(
                    day: day,
                    hours: hours,
                    isActive: boolValue(dayData["isActive"]) ?? false
                )
            }

            let totalHours = doubleValue(employee["totalHours"])
                ?? dayValues.reduce(0) { $0 + $1.hours }

            return WorkScheduleEmployee(
                id: id,
                name: identity.name,
                login: identity.login ?? "",
                totalHours: totalHours,
                dayValues: dayValues
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dailyTotals = (1...daysInMonth).map { day in
            WorkScheduleDailyTotal(
                day: day,
                count: employees.reduce(into: 0) { count, employee in
                    if employee.value(for: day)?.isActive == true {
                        count += 1
                    }
                }
            )
        }

        return WorkSchedule(
            journal: journal,
            daysInMonth: daysInMonth,
            employees: employees,
            dailyTotals: dailyTotals,
            auditInfo: auditInfo
        )
    }

    public static func auditInfo(from response: [String: Any]) -> WorkScheduleAuditInfo? {
        let info = WorkScheduleAuditInfo(
            createdBy: auditPerson(for: "sys_created_by", in: response),
            createdAt: auditDate(for: "sys_created_at", in: response),
            updatedBy: auditPerson(for: "sys_updated_by", in: response),
            updatedAt: auditDate(for: "sys_updated_at", in: response)
        )
        return info.hasContent ? info : nil
    }

    public static func widgetInstanceID(from response: [String: Any]) throws -> String {
        let candidates = widgetCandidates(in: response)
        if let scheduleWidget = candidates.first(where: \.isScheduleWidget) {
            return scheduleWidget.id
        }
        if candidates.count == 1, let widgetID = candidates.first?.id {
            return widgetID
        }
        throw WorkScheduleParsingError.missingWidgetInstanceID
    }

    private static func widgetCandidates(in value: Any) -> [(id: String, isScheduleWidget: Bool)] {
        var candidates: [(id: String, isScheduleWidget: Bool)] = []
        collectWidgetCandidates(in: value, into: &candidates)
        return candidates
    }

    private static func collectWidgetCandidates(
        in value: Any,
        into candidates: inout [(id: String, isScheduleWidget: Bool)]
    ) {
        if let object = dictionary(value) {
            if let widgetID = stringValue(object["widget_instance_id"]), !widgetID.isEmpty {
                let markerText = [
                    "client_script", "template", "name", "widget_name", "title"
                ]
                .compactMap { stringValue(object[$0]) }
                .joined(separator: " ")
                .lowercased()
                let isScheduleWidget = markerText.contains("scheduledata")
                    || markerText.contains("daysinmonth")
                    || markerText.contains("график")
                candidates.append((widgetID, isScheduleWidget))
            }
            for nested in object.values {
                collectWidgetCandidates(in: nested, into: &candidates)
            }
        } else if let values = value as? [Any] {
            for nested in values {
                collectWidgetCandidates(in: nested, into: &candidates)
            }
        }
    }

    private static func scheduleDictionary(_ value: Any) -> [String: Any]? {
        if let value = dictionary(value) {
            if let wrapped = value["value"], value.keys.allSatisfy({
                ["value", "display_value", "database_value"].contains($0)
            }) {
                return scheduleDictionary(wrapped)
            }
            return value
        }
        guard let text = stringValue(value),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return dictionary(object)
    }

    private static func recursivelyFindValue(for key: String, in value: Any) -> Any? {
        if let object = dictionary(value) {
            if let match = object[key] {
                return match
            }
            for nested in object.values {
                if let match = recursivelyFindValue(for: key, in: nested) {
                    return match
                }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let match = recursivelyFindValue(for: key, in: nested) {
                    return match
                }
            }
        }
        return nil
    }

    private static func auditPerson(for columnName: String, in response: [String: Any]) -> String? {
        guard let field = field(named: columnName, in: response),
              let value = fieldDisplayValue(field["value"])
        else {
            return nil
        }
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func auditDate(for columnName: String, in response: [String: Any]) -> Date? {
        guard let field = field(named: columnName, in: response),
              let rawValue = fieldDatabaseValue(field["value"])
        else {
            return nil
        }

        let iso8601Value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "T")
        return ISO8601DateFormatter().date(from: "\(iso8601Value)Z")
    }

    private static func field(named columnName: String, in value: Any) -> [String: Any]? {
        if let object = dictionary(value) {
            if stringValue(object["sys_column_name"]) == columnName {
                return object
            }
            for nested in object.values {
                if let field = field(named: columnName, in: nested) {
                    return field
                }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let field = field(named: columnName, in: nested) {
                    return field
                }
            }
        }
        return nil
    }

    private static func employeeIdentity(from displayName: String) -> (name: String, login: String?) {
        let pattern = #"^(.*?)\s*\(([^()]*)\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: displayName,
                range: NSRange(displayName.startIndex..., in: displayName)
              ),
              let nameRange = Range(match.range(at: 1), in: displayName),
              let loginRange = Range(match.range(at: 2), in: displayName)
        else {
            return (displayName.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        return (
            String(displayName[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(displayName[loginRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isAggregateRow(_ displayName: String) -> Bool {
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("всего") && normalized.contains("работ")
    }

    private static func fieldDatabaseValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let object = dictionary(value), let wrapped = object["value"] {
            return fieldDatabaseValue(wrapped)
        }
        if let object = dictionary(value) {
            return stringValue(object["database_value"])
                ?? stringValue(object["value"])
                ?? stringValue(object["sys_id"])
        }
        return stringValue(value)
    }

    private static func fieldDisplayValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let object = dictionary(value), let wrapped = object["value"] {
            return fieldDisplayValue(wrapped)
        }
        if let object = dictionary(value) {
            return stringValue(object["display_value"])
                ?? stringValue(object["display_value_translation"])
                ?? fieldDatabaseValue(value)
        }
        return stringValue(value)
    }

    private static func monthNumber(_ value: String?) -> Int? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty
        else {
            return nil
        }
        if let month = Int(normalized), (1...12).contains(month) {
            return month
        }
        return [
            "январь": 1, "января": 1,
            "февраль": 2, "февраля": 2,
            "март": 3, "марта": 3,
            "апрель": 4, "апреля": 4,
            "май": 5, "мая": 5,
            "июнь": 6, "июня": 6,
            "июль": 7, "июля": 7,
            "август": 8, "августа": 8,
            "сентябрь": 9, "сентября": 9,
            "октябрь": 10, "октября": 10,
            "ноябрь": 11, "ноября": 11,
            "декабрь": 12, "декабря": 12
        ][normalized]
    }

    private static func calendarDaysInMonth(year: Int, month: Int) -> Int {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = 1
        guard let date = components.date,
              let range = components.calendar?.range(of: .day, in: .month, for: date)
        else {
            return 31
        }
        return range.count
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as [String: Any]:
            return stringValue(value["value"])
                ?? stringValue(value["database_value"])
                ?? stringValue(value["display_value"])
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        if let object = dictionary(value) {
            return intValue(object["value"])
                ?? intValue(object["database_value"])
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
