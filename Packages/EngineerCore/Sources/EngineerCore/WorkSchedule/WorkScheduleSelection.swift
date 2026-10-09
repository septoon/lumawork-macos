import Foundation

public struct WorkScheduleSelectionState: Equatable, Sendable {
    public let cityName: String
    public let year: Int
    public let month: Int
    public init(cityName: String, year: Int, month: Int) { self.cityName = cityName; self.year = year; self.month = month }
}

public enum WorkScheduleSelection {
    public static func initial(
        journals: [WorkScheduleJournal],
        profileCity: String?,
        currentYear: Int,
        currentMonth: Int
    ) -> WorkScheduleSelectionState {
        let cities = cityNames(in: journals)
        let profileCity = profileCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedCity = cities.first { normalized($0) == normalized(profileCity) }
            ?? cities.first
            ?? ""
        return WorkScheduleSelectionState(
            cityName: selectedCity,
            year: currentYear,
            month: currentMonth
        )
    }

    public static func cityNames(in journals: [WorkScheduleJournal]) -> [String] {
        var namesByKey: [String: String] = [:]
        for journal in journals {
            namesByKey[normalized(journal.cityName)] = journal.cityName
        }
        return namesByKey.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    public static func years(
        in journals: [WorkScheduleJournal],
        cityName: String
    ) -> [Int] {
        Array(Set(journals.lazy
            .filter { normalized($0.cityName) == normalized(cityName) }
            .map(\.year)))
            .sorted(by: >)
    }

    public static func months(
        in journals: [WorkScheduleJournal],
        cityName: String,
        year: Int
    ) -> [Int] {
        Array(Set(journals.lazy
            .filter {
                normalized($0.cityName) == normalized(cityName) && $0.year == year
            }
            .map(\.month)))
            .sorted()
    }

    public static func journal(
        in journals: [WorkScheduleJournal],
        matching selection: WorkScheduleSelectionState
    ) -> WorkScheduleJournal? {
        journals.first {
            normalized($0.cityName) == normalized(selection.cityName)
                && $0.year == selection.year
                && $0.month == selection.month
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum WorkScheduleViewport {
    public static func currentDay(
        in journal: WorkScheduleJournal,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard components.year == journal.year,
              components.month == journal.month else {
            return nil
        }
        return components.day
    }

    public static func initialVisibleDay(
        in journal: WorkScheduleJournal,
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard let currentDay = currentDay(in: journal, now: now, calendar: calendar) else {
            return 1
        }
        return max(1, currentDay - 1)
    }
}
