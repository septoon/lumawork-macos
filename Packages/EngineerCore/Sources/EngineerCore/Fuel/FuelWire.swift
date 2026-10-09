import Foundation

public enum FuelWire {
    public static func records(_ raw: Any?) throws -> [FuelRecord] {
        guard let root = raw as? [String: Any], let rows = root["records"] as? [[String: Any]] else { throw GsmFuelError.invalidResponse }
        return try rows.map(record)
    }
    public static func record(_ row: [String: Any]) throws -> FuelRecord {
        guard !stringValue(row["date"]).isEmpty else { throw GsmFuelError.invalidResponse }
        return FuelRecord(id: stringValue(row["id"] ?? row["_id"]).nonempty, recordType: stringValue(row["recordType"]).lowercased() == "adjustment" ? .adjustment : .fuel,
                          adjustmentKind: FuelRecord.AdjustmentKind(rawValue: stringValue(row["adjustmentKind"]).lowercased()),
                          monthKey: stringValue(row["monthKey"]).nonempty, amount: doubleValue(row["amount"]), carryoverDebtRub: doubleValue(row["carryoverDebtRub"]), comment: stringValue(row["comment"]).nonempty,
                          date: stringValue(row["date"]), mileage: doubleValue(row["mileage"]), liters: doubleValue(row["liters"]), fuelCost: doubleValue(row["fuelCost"]),
                          fuelType: stringValue(row["fuelType"]).nonempty, fuelConsumptionRate: doubleValue(row["fuelConsumptionRate"]), source: stringValue(row["source"]).nonempty, sourceImportId: stringValue(row["sourceImportId"]).nonempty)
    }
    public static func payload(_ value: FuelRecord) throws -> [String: Any] {
        guard validDate(value.date) else { throw AppServiceError.message("Укажите корректную дату записи.") }
        for number in [value.mileage, value.liters, value.fuelCost, value.amount, value.carryoverDebtRub].compactMap({ $0 }) {
            guard number.isFinite, number >= 0 else { throw AppServiceError.message("Числовые значения должны быть неотрицательными.") }
        }
        if value.recordType == .fuel {
            guard value.mileage != nil || value.liters != nil || value.fuelCost != nil else { throw AppServiceError.message("Укажите пробег, бензин или стоимость перед отправкой.") }
            if value.date >= "2026-04-01", value.liters != nil || value.fuelCost != nil {
                guard value.fuelType?.nonempty != nil else { throw AppServiceError.message("Выберите тип топлива.") }
                guard value.liters != nil, value.fuelCost != nil else { throw AppServiceError.message("Начиная с 2026-04-01 укажите литры и сумму заправки для Excel-отчёта.") }
            }
        } else {
            guard let kind = value.adjustmentKind else { throw AppServiceError.message("Укажите тип корректировки.") }
            if let month = value.monthKey, !month.isEmpty, !GsmWire.isValidMonth(month) { throw AppServiceError.message("Некорректный месяц корректировки.") }
            if kind == .compensationPayment, value.amount == nil { throw AppServiceError.message("Для выплаты укажите сумму.") }
            if kind == .debtDeduction, value.amount == nil, value.liters == nil { throw AppServiceError.message("Для вычета долга укажите сумму или литры.") }
        }
        var payload: [String: Any] = ["date": value.date, "recordType": value.recordType.rawValue]
        payload["id"] = value.id; payload["adjustmentKind"] = value.adjustmentKind?.rawValue
        payload["monthKey"] = value.monthKey; payload["amount"] = value.amount; payload["carryoverDebtRub"] = value.carryoverDebtRub
        payload["comment"] = value.comment?.nonempty; payload["mileage"] = value.mileage; payload["liters"] = value.liters
        payload["fuelCost"] = value.fuelCost; payload["fuelType"] = value.fuelType?.nonempty
        return payload
    }
    public static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
    public static func monthlyMileageIndex(records: [FuelRecord], month: String) -> Int? {
        let indices = records.indices.filter { records[$0].recordType == .fuel && records[$0].date.hasPrefix(month + "-") }
        if let tagged = indices.first(where: { records[$0].comment?.hasPrefix("route_monthly_mileage") == true }) { return tagged }
        return indices.filter { records[$0].mileage != nil && records[$0].liters == nil && records[$0].fuelCost == nil }
            .max { (records[$0].date, records[$0].stableID) < (records[$1].date, records[$1].stableID) }
    }
}
public struct RouteMonthlyMileage: Equatable, Sendable {
    public let monthKey: String
    public let latestDate: String
    public let totalKm: Int
    public static func build(month: String, days: [RouteDayRecord]) -> Self? {
        let days = days.filter { $0.date.hasPrefix(month + "-") && $0.distanceKm != nil }
        guard let latest = days.map(\.date).max() else { return nil }
        return Self(monthKey: month, latestDate: latest, totalKm: days.reduce(0) { $0 + ($1.distanceKm ?? 0) })
    }
    public func record(replacing target: FuelRecord?) -> FuelRecord {
        FuelRecord(id: target?.id, comment: "route_monthly_mileage|\(latestDate)|\(totalKm)", date: latestDate, mileage: Double(totalKm))
    }
}
extension String { var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }
