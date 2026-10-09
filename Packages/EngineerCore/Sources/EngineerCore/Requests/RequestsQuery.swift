import Foundation

public enum RequestsScope: String, CaseIterable, Identifiable, Sendable {
    case active, closed, warehouse
    public var id: String { rawValue }
    public var title: String {
        switch self { case .active: "Активные"; case .closed: "Закрытые"; case .warehouse: "Складские" }
    }
    public var source: SimpleOneRequestSource { self == .closed ? .closed : .active }
}

public struct SimpleOneQueryConfiguration: Sendable {
    public static let fields: [(key: String, title: String)] = [
        ("SIMPLEONE_PRIMARY_ASSIGNMENT_GROUP_ID", "Основная рабочая группа"),
        ("SIMPLEONE_CURRENT_REGION_ASSIGNMENT_GROUP_ID", "Региональная рабочая группа"),
        ("SIMPLEONE_CURRENT_COMPANY_LOCATION_ID", "Расположение компании"),
        ("SIMPLEONE_CURRENT_USER_DYNAMIC_ID", "Текущий пользователь (dynamic)"),
        ("SIMPLEONE_ASSIGNED_USER_DYNAMIC_ID", "Исполнитель (dynamic)"),
        ("SIMPLEONE_RESOLVED_DATE_OPTION_ID", "Опция даты выполнения")
    ]
    private let values: [String: String]
    public init(values: [String: String]? = nil) {
        if let values { self.values = values; return }
        let local = Bundle.main.url(forResource: "SimpleOne.local", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        self.values = Dictionary(uniqueKeysWithValues: Self.fields.map { field in
            (field.key, AppConfig.resolveFirst(field.key) ?? local[field.key] ?? "")
        })
    }
    public func value(for key: String) -> String { values[key] ?? "" }
    private func required(_ key: String) throws -> String {
        let value = value(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else {
            throw SimpleOneServiceError.server("Не настроены фильтры SimpleOne. Укажите идентификаторы в настройках приложения.")
        }
        return value
    }
    public func condition(scope: RequestsScope, userID: String) throws -> String {
        guard !userID.isEmpty, userID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw SimpleOneServiceError.invalidResponse }
        if scope != .closed {
            let group = try required("SIMPLEONE_PRIMARY_ASSIGNMENT_GROUP_ID")
            let region = try required("SIMPLEONE_CURRENT_REGION_ASSIGNMENT_GROUP_ID")
            let location = try required("SIMPLEONE_CURRENT_COMPANY_LOCATION_ID")
            return "((assignment_group=\(group)^ORassignment_group=\(region))^related_inquiry.company_location=\(location)^client_service_idLIKEСервисные заявки БЧ^client_service_idNOTLIKEЭкспертиза. Сервисные заявки БЧ^stateNOT INcancelled@closed@escalated@completed^assigned_user=\(userID))"
        }
        let current = try required("SIMPLEONE_CURRENT_USER_DYNAMIC_ID")
        let assigned = try required("SIMPLEONE_ASSIGNED_USER_DYNAMIC_ID")
        let date = try required("SIMPLEONE_RESOLVED_DATE_OPTION_ID")
        return "((multicard_engineerDYNAMIC\(current)^ORassigned_userDYNAMIC\(assigned)^ORengineer_schedule.employeeDYNAMIC\(current))^resolved_atNOTONopt:\(date)^stateNOT INon_hold@assigned@in_progress@escalated@returned_to_work@3@6@update_received)"
    }
}

public enum RequestsPolicy {
    private static let dateFormatters = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "MM.dd.yyyy HH:mm:ss", "MM.dd.yyyy HH:mm", "yyyy-MM-dd", "dd.MM.yyyy"].map { format in
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format
        return formatter
    }
    public static func isReturnEquipment(_ raw: String) -> Bool {
        let type = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "returnequip" || type == "return_equip" || type.contains("возврат")
    }
    public static func isWarehouse(_ record: SimpleOneRequestRecord) -> Bool {
        if isReturnEquipment(record.requestType) { return true }
        let texts = [record.shortDescription, record.assignmentGroup, record.clientServiceParent ?? "", record.clientService ?? "", record.informationText]
            + (record.tableFields ?? []).map { "\($0.key): \($0.value)" }
        return texts.contains { raw in
            let text = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return text.contains("город склада") || text.contains("складская заявка") || text.contains("складские заявки") || text.contains("номер принятого оборудования")
        }
    }
    public static func includedInArchive(_ record: SimpleOneRequestRecord) -> Bool {
        if isReturnEquipment(record.requestType) { return true }
        let status = record.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["completed", "closed", "resolved"].contains(status) || ["выполн", "закрыт", "решен", "решён", "отказ", "отклон"].contains { status.contains($0) }
    }
    public static func date(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw), Calendar(identifier: .gregorian).component(.year, from: date) > 1970 { return date }
        }
        return nil
    }
    public static func effectiveTime(_ record: SimpleOneRequestRecord) -> String {
        if isReturnEquipment(record.requestType), let registered = record.registeredAt, date(registered) != nil { return registered }
        return record.resolvedAt
    }
    public static func multicardStatus(_ record: SimpleOneRequestRecord) -> String {
        let status = record.tableFields?.first { $0.key.lowercased() == "мк статус" }?.value ?? ""
        return status.isEmpty ? record.state : status
    }
    public static func typeTitle(_ raw: String) -> String {
        switch raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw {
        case "install": "Установка"; case "dismounting": "Демонтаж"; case "returnEquip": "Возврат ТО"
        case "serviceStd": "Сервисная"; case "replacement": "Замена"; default: raw
        }
    }
}
