import Foundation

public enum GsmWire {
    public static func isValidMonth(_ month: String) -> Bool { month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
    public static func profile(_ raw: Any?) throws -> GsmProfileLoadResult {
        guard let root = raw as? [String: Any] else { throw GsmFuelError.invalidResponse }
        let available = (root["availableFuelTypes"] as? [Any] ?? []).map { stringValue($0) }.filter { !$0.isEmpty }
        let nested = ["profile", "gsmProfile", "gsm_profile", "data"].compactMap { root[$0] as? [String: Any] }.first
        if root["profile"] is NSNull { return GsmProfileLoadResult(profile: .empty, availableFuelTypes: available) }
        guard let row = nested ?? (root.keys.contains { $0.lowercased().contains("employee") || $0.lowercased().contains("budget") } ? root : nil) else { throw GsmFuelError.invalidResponse }
        var value = GsmProfile.empty
        // Accept the same camelCase/snake_case legacy fields as the existing iOS mapper.
        var normalized: [String: Any] = [:]
        for key in GsmProfile.CodingKeys.allCases {
            let snake = key.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            if let input = row[key.rawValue] ?? row[snake], !(input is NSNull) { normalized[key.rawValue] = input }
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        for (key, defaultValue) in base {
            let raw = normalized[key] ?? defaultValue
            if defaultValue is String { normalized[key] = stringValue(raw) }
        }
        normalized["fuelNorm"] = doubleValue(normalized["fuelNorm"]) ?? 0
        normalized["defaultStartOdometer"] = intValue(normalized["defaultStartOdometer"]) ?? 0
        if let types = normalized["fuelTypes"] as? [Any], !types.isEmpty { normalized["fuelTypes"] = types.map { stringValue($0) }.filter { !$0.isEmpty } }
        else { let legacy = stringValue(normalized["fuelType"]); normalized["fuelTypes"] = legacy.isEmpty ? [] : [legacy] }
        value = try JSONDecoder().decode(GsmProfile.self, from: JSONSerialization.data(withJSONObject: normalized))
        value.employeePhone = GsmPhoneFormatter.format(value.employeePhone)
        return GsmProfileLoadResult(profile: value, availableFuelTypes: available)
    }
    public static func projects(_ raw: Any?) throws -> [GsmProjectOption] {
        guard let root = raw as? [String: Any], let rows = root["projects"] as? [[String: Any]] else { throw GsmFuelError.invalidResponse }
        return rows.compactMap { row in
            let id = stringValue(row["id"]), name = stringValue(row["name"]), budget = stringValue(row["budgetCode"])
            guard !id.isEmpty, !name.isEmpty, !budget.isEmpty else { return nil }
            return GsmProjectOption(id: id, name: name, budgetCode: budget)
        }
    }
    public static func profilePayload(_ input: GsmProfile) throws -> [String: Any] {
        var profile = input; profile.employeePhone = GsmPhoneFormatter.format(input.employeePhone)
        guard GsmPhoneFormatter.isComplete(profile.employeePhone) else { throw AppServiceError.message("Введите телефон полностью: +7(XXX)XXX-XX-XX.") }
        guard [profile.employeeFullName, profile.employeeShortName, profile.employeeReportSignName, profile.authorizedFullName, profile.authorizedShortName, profile.employeeJobTitle, profile.employeeCompany, profile.employeeAddress, profile.driverLicenseNumber, profile.fuelCardNumber, profile.carModel, profile.licensePlate].allSatisfy({ $0.nonempty != nil }), profile.posProjectID != nil,
              profile.fuelNorm.isFinite, profile.fuelNorm > 0, !profile.fuelTypes.isEmpty, profile.defaultStartOdometer >= 0, isValidMonth(profile.reportStartMonth) else { throw AppServiceError.message("Заполните обязательные поля ГСМ профиля, проект POS, норму и типы топлива.") }
        profile.fuelType = profile.fuelTypes[0]
        profile.employeeTitleCompany = [profile.employeeFullName, profile.employeeJobTitle, profile.employeeCompany].joined(separator: ", ")
        profile.employeeAddressPhone = [profile.employeeAddress, profile.employeePhone].joined(separator: ", ")
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        body["vehicleId"] = profile.vehicleID ?? NSNull(); body["posProjectId"] = profile.posProjectID ?? NSNull(); body["armProjectId"] = profile.armProjectID ?? NSNull()
        return body
    }
}
