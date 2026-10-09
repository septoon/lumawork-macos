import Foundation

public enum CoordinationSection: String, CaseIterable, Identifiable, Sendable {
    case distribution
    case returnEquipment

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .distribution:
            "На группу"
        case .returnEquipment:
            "Возврат ТО"
        }
    }
}

public enum CoordinationRegion: String, CaseIterable, Codable, Identifiable, Sendable {
    case simferopol
    case alushta
    case yalta
    case evpatoria
    case krasnoperekopsk
    case dzhankoy
    case feodosia
    case kerch
    case sevastopol

    public static let defaultRegion: CoordinationRegion = .alushta

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simferopol:
            "Симферополь"
        case .alushta:
            "Алушта"
        case .yalta:
            "Ялта"
        case .evpatoria:
            "Евпатория"
        case .krasnoperekopsk:
            "Красноперекопск"
        case .dzhankoy:
            "Джанкой"
        case .feodosia:
            "Феодосия"
        case .kerch:
            "Керчь"
        case .sevastopol:
            "Севастополь"
        }
    }

    public var assignmentGroupID: String {
        SimpleOneQueryConfiguration().value(for: "SIMPLEONE_\(rawValue.uppercased())_ASSIGNMENT_GROUP_ID")
    }

    public var companyLocationID: String {
        SimpleOneQueryConfiguration().value(for: "SIMPLEONE_\(rawValue.uppercased())_COMPANY_LOCATION_ID")
    }

}

public func isCoordinationReturnEquipmentRequestType(_ raw: String) -> Bool {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")

    return normalized == "returnequip" || normalized.contains("возвратто")
}

public func isCoordinationExpertiseRequestType(_ raw: String) -> Bool {
    let normalized = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")

    return normalized.contains("экспертиз") || normalized.contains("expert")
}

public struct CoordinationEngineer: Hashable, Identifiable, Sendable {
    public static let unassignedID = "coordination:unassigned"

    public let id: String
    public let name: String
    public let requestCount: Int

    public var isUnassigned: Bool {
        id == Self.unassignedID
    }
}

public enum RequestCollection: Hashable, Sendable {
    case personal(SimpleOneRequestSource)
    case coordination(CoordinationRegion)
    case returnEquipment
    case groupClosed
    public var key: String {
        switch self {
        case .personal(let source): "personal/" + source.rawValue
        case .coordination(let region): "coordination/" + region.rawValue
        case .returnEquipment: "return-equipment"
        case .groupClosed: "group-closed"
        }
    }
    public var source: SimpleOneRequestSource {
        switch self { case .personal(let source): source; case .groupClosed: .closed; default: .active }
    }
    public var title: String {
        switch self { case .personal(let source): source == .active ? "Активные" : "Закрытые"; case .coordination: "Заявки группы"; case .returnEquipment: "Возврат ТО"; case .groupClosed: "Закрытые группы" }
    }
}

public enum CoordinationPolicy {
    public static func returnEquipmentSerial(_ request: SimpleOneRequestRecord) -> String {
        func normalized(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        let parsed = request.informationText.components(separatedBy: .newlines).compactMap { line -> ClosedRequestInfoField? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            return ClosedRequestInfoField(key: String(line[..<separator]), value: String(line[line.index(after: separator)...]))
        }
        let fields = (request.tableFields ?? []) + parsed
        for label in ["Серийный номер демонтируемого ТО", "S/N терминала", "Номер принятого оборудования POS", "Оборудование POS"] {
            if let value = fields.first(where: { normalized($0.key) == normalized(label) && !normalized($0.value).isEmpty && normalized($0.value) != "информация отсутствует" })?.value { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return ""
    }
    public static func engineerKey(_ request: SimpleOneRequestRecord) -> String {
        let name = request.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !name.isEmpty { return "name:" + name }
        if let id = request.assignedUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return "id:" + id }
        return CoordinationEngineer.unassignedID
    }
    public static func engineers(_ requests: [SimpleOneRequestRecord]) -> [CoordinationEngineer] {
        Dictionary(grouping: requests, by: engineerKey).map { key, records in
            let name = records.first?.assignedUser.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CoordinationEngineer(id: key, name: key == CoordinationEngineer.unassignedID ? "Назначено на группу" : name.isEmpty ? "Исполнитель не определён" : name, requestCount: records.count)
        }.sorted {
            if $0.isUnassigned != $1.isUnassigned { return $0.isUnassigned }
            if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
