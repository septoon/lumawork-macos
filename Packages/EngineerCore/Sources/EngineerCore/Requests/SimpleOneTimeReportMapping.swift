import Foundation

extension SimpleOneRequestsService {
    func makeTimeReportEntry(from item: [String: Any]) -> TimeReportEntry? {
        let activity = timeReportValue(
            item,
            "acticvity",
            "activity",
            "task",
            "itsm_request",
            "source_task",
            "Активность",
            "Задача",
            "Задача.Активность"
        )
        let createdAtRaw = timeReportValue(item, "sys_created_at", "created_at", "Когда создано")
        let workDateRaw = timeReportValue(item, "date_of_work", "Дата проведения работ")
        guard !activity.isEmpty,
              let createdAt = parseTimeReportDate(createdAtRaw) ?? parseTimeReportDate(workDateRaw) else {
            return nil
        }

        let workMinutes = parseTimeReportWorkMinutes(
            durationText: timeReportValue(item, "time_of_work", "work_time", "work_duration", "time_work", "Время работ"),
            hoursText: timeReportValue(item, "time_of_work_hours", "work_hours", "time_work_hours", "Время работ (ч)"),
            minutesText: timeReportValue(item, "time_of_work_minutes", "work_minutes", "time_work_minutes", "Время работ (м)")
        )
        let travelMinutes = parseTimeReportWorkMinutes(
            durationText: timeReportValue(item, "travel_time", "time_on_road", "Время в дороге"),
            hoursText: timeReportValue(item, "travel_time_hours", "travel_hours", "time_on_road_hours", "Время в дороге (ч)"),
            minutesText: timeReportValue(item, "travel_time_minutes", "travel_minutes", "time_on_road_minutes", "Время в дороге (м)")
        )
        let overtimeMinutes = parseTimeReportHourMinuteFields(
            hoursText: timeReportValue(item, "extracurricular_activities_hours", "overtime_hours", "over_time_hours", "Внеурочные работы (ч.)"),
            minutesText: timeReportValue(item, "overtime_minutes", "over_time_minutes", "Внеурочные работы (м)")
        )
        let simpleOneRecordID = timeReportValue(item, "sys_id", "id", "ID")

        return TimeReportEntry(
            activity: activity,
            simpleOneRecordID: simpleOneRecordID.isEmpty ? nil : simpleOneRecordID,
            period: timeReportValue(item, "month", "period", "Период"),
            createdAt: createdAt,
            createdAtRaw: firstNonEmpty(createdAtRaw, workDateRaw),
            workDate: parseTimeReportDate(workDateRaw),
            workDateRaw: workDateRaw.isEmpty ? nil : workDateRaw,
            workMinutes: workMinutes,
            travelMinutes: travelMinutes,
            overtimeMinutes: overtimeMinutes,
            notes: timeReportValue(item, "result", "work_notes", "notes", "Рабочие заметки"),
            nonWorkCosts: timeReportValue(item, "extracurricular_time", "non_work_costs", "non_work_time", "Трудозатраты нерабочие"),
            isOvertime: parseTimeReportBool(timeReportValue(item, "extracurricular_work", "overtime", "is_overtime", "Внеурочные работы")),
            executor: timeReportValue(item, "person", "person.c_full_name", "executor", "executor.c_full_name", "Исполнитель")
        )
    }

    func timeReportValue(_ item: [String: Any], _ keys: String...) -> String {
        let value = keys
            .map { fieldDisplayString(item, $0) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "(не задано)" ? "" : value
    }

    func parseTimeReportWorkMinutes(durationText: String, hoursText: String, minutesText: String) -> Int {
        let parsedMinutes = parseTimeReportDurationMinutes(durationText)
        if parsedMinutes > 0 {
            return parsedMinutes
        }
        return parseTimeReportHourMinuteFields(hoursText: hoursText, minutesText: minutesText)
    }

    func parseTimeReportHourMinuteFields(hoursText: String, minutesText: String) -> Int {
        safeMinutes(parseTimeReportDouble(hoursText) * 60)
            + safeMinutes(parseTimeReportDouble(minutesText))
    }

    func parseTimeReportDurationMinutes(_ raw: String) -> Int {
        let normalized = raw
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return 0 }

        if let numericValue = Double(normalized), numericValue > 0 {
            if numericValue >= 60_000 {
                return safeMinutes(numericValue / 60_000)
            }
            return safeMinutes(numericValue)
        }

        let hours = sumTimeReportMatches(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:hours?|hour|час(?:а|ов)?|ч|h)"#,
            in: normalized
        )
        let minutes = sumTimeReportMatches(
            pattern: #"(\d+(?:\.\d+)?)\s*(?:minutes?|minute|мин(?:ут(?:а|ы)?)?|м|m)"#,
            in: normalized
        )
        return safeMinutes(hours * 60 + minutes)
    }

    func sumTimeReportMatches(pattern: String, in raw: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return 0
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.matches(in: raw, range: range).reduce(0) { partialResult, match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: raw) else {
                return partialResult
            }
            return partialResult + (Double(raw[valueRange]) ?? 0)
        }
    }

    private func safeMinutes(_ value: Double) -> Int { value.isFinite ? Int(exactly: value.rounded()) ?? 0 : 0 }

    func parseTimeReportDouble(_ raw: String) -> Double {
        Double(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    func parseTimeReportBool(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "да", "истина":
            return true
        default:
            return false
        }
    }

    func parseTimeReportDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for formatter in Self.timeReportDateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    static let timeReportDateFormatters: [DateFormatter] = {
        let formats = [
            "dd.MM.yyyy HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd.MM.yyyy H:mm:ss",
            "dd.MM.yyyy H:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "dd.MM.yyyy"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if format.hasPrefix("yyyy-MM-dd") {
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
            }
            formatter.dateFormat = format
            return formatter
        }
    }()
}
