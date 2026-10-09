import Foundation

public struct OfficeEquipmentField: Codable, Hashable, Identifiable, Sendable {
    public let systemName: String
    public let title: String
    public let value: String

    public var id: String { systemName + "|" + title }
}

public struct OfficeEquipmentSection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let fields: [OfficeEquipmentField]
}

public struct OfficeEquipmentItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let serialNumber: String
    public let vendor: String
    public let type: String
    public let model: String
    public let number: String
    public let location: String
    public let owner: String
    public let receivedAt: String
    public let receivedAtDate: Date?
    public let alternativeName: String
    public let additionalInformation: String
    public let description: String
    public let detailSections: [OfficeEquipmentSection]

    public var displayName: String {
        firstNonEmpty(alternativeName, name, [vendor, model].filter { !$0.isEmpty }.joined(separator: " "), model, "Оборудование")
    }

    public var photoReferenceName: String {
        firstNonEmpty(alternativeName, [vendor, model].filter { !$0.isEmpty }.joined(separator: " "), model, name)
    }

    public var photoCandidateNames: [String] {
        officeEquipmentUniqueStrings([
            alternativeName,
            name,
            [vendor, model].filter { !$0.isEmpty }.joined(separator: " "),
            model
        ])
    }
}

extension SimpleOneRequestsService {
    public func fetchCurrentOfficeEquipment(authKey: String) async throws -> [OfficeEquipmentItem] {
        let currentUserDynamicID = try query.required("SIMPLEONE_CURRENT_USER_DYNAMIC_ID")
        return try await fetchOfficeEquipment(
            condition: "(ownerDYNAMIC\(currentUserDynamicID))",
            authKey: authKey
        )
    }

    public func fetchOfficeEquipment(login: String, authKey: String) async throws -> [OfficeEquipmentItem] {
        let employeeID = try await fetchEmployeeID(login: login, authKey: authKey)
        return try await fetchOfficeEquipment(condition: "(owner=\(employeeID))", authKey: authKey)
    }

    private func fetchEmployeeID(login: String, authKey: String) async throws -> String {
        let normalizedLogin = officeEquipmentConditionValue(login)
        guard !normalizedLogin.isEmpty,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("list/employee"),
                  resolvingAgainstBaseURL: false
              ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: "(username=\(normalizedLogin))"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "20")
        ]
        guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
        let response = try await request(url: url, authKey: authKey)
        guard let records = listItems( response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }
        let exact = records.first { record in
            fieldString(record, "username").localizedCaseInsensitiveCompare(normalizedLogin) == .orderedSame
        }
        guard let employeeID = exact.map({ firstNonEmpty(fieldString($0, "sys_id"), stringValue($0["sys_id"])) }),
              !employeeID.isEmpty else {
            throw AppServiceError.message("Пользователь SimpleOne «\(normalizedLogin)» не найден.")
        }
        return employeeID
    }

    private func fetchOfficeEquipment(
        condition: String,
        authKey: String
    ) async throws -> [OfficeEquipmentItem] {
        var page = 1
        let perPage = 100
        var items: [OfficeEquipmentItem] = []
        var seenIDs = Set<String>()

        while true {
            try Task.checkCancellation()
            guard var components = URLComponents(
                url: baseURL.appendingPathComponent("list/itsm_tchnsrv_office_equipment"),
                resolvingAgainstBaseURL: false
            ) else {
                throw SimpleOneServiceError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "condition", value: condition),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
            guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
            let response = try await request(url: url, authKey: authKey)
            guard let records = listItems( response) else {
                throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
            }
            let previousCount = items.count
            for record in records {
                let item = officeEquipmentItem(from: record)
                guard !item.id.isEmpty, seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }
            let hasMore = totalCount( response).map { page * perPage < $0 }
                ?? (records.count == perPage)
            guard hasMore else { break }
            guard items.count > previousCount else { throw SimpleOneServiceError.invalidResponse }
            page += 1
        }

        let detailed = try await officeEquipmentDetails(items, authKey: authKey)
        return detailed.sorted { lhs, rhs in
            switch (lhs.receivedAtDate, rhs.receivedAtDate) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func officeEquipmentDetails(
        _ items: [OfficeEquipmentItem],
        authKey: String
    ) async throws -> [OfficeEquipmentItem] {
        try await withThrowingTaskGroup(of: (Int, OfficeEquipmentItem).self) { group in
            var iterator = items.enumerated().makeIterator()

            func enqueue(_ index: Int, _ item: OfficeEquipmentItem) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let response = try await request(
                            path: "/record/itsm_tchnsrv_office_equipment/\(item.id)",
                            authKey: authKey
                        )
                        guard let record = recordItem(from: response) else {
                            throw SimpleOneServiceError.invalidResponse
                        }
                        return (index, officeEquipmentItem(from: record, fallback: item))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch SimpleOneServiceError.forbidden {
                        throw SimpleOneServiceError.forbidden
                    } catch SimpleOneServiceError.unauthorized {
                        throw SimpleOneServiceError.unauthorized
                    } catch {
                        return (index, item)
                    }
                }
            }

            for _ in 0..<min(4, items.count) {
                if let (index, item) = iterator.next() { enqueue(index, item) }
            }
            var result = items
            while let (index, item) = try await group.next() {
                result[index] = item
                if let (nextIndex, nextItem) = iterator.next() { enqueue(nextIndex, nextItem) }
            }
            return result
        }
    }

    private func officeEquipmentItem(
        from raw: [String: Any],
        fallback: OfficeEquipmentItem? = nil
    ) -> OfficeEquipmentItem {
        let flattened = flattenedRecordItem(from: raw)
        let receivedAt = firstNonEmpty(fieldString(flattened, "sys_updated_at"), fallback?.receivedAt ?? "")
        let details = officeEquipmentSections(from: raw)
        return OfficeEquipmentItem(
            id: firstNonEmpty(fieldString(flattened, "sys_id"), stringValue(flattened["record_id"]), fallback?.id ?? ""),
            name: firstNonEmpty(fieldString(flattened, "name"), fallback?.name ?? ""),
            serialNumber: firstNonEmpty(fieldString(flattened, "serial_number"), fallback?.serialNumber ?? ""),
            vendor: firstNonEmpty(fieldDisplayString(flattened, "c_vendor"), fallback?.vendor ?? ""),
            type: firstNonEmpty(fieldDisplayString(flattened, "ci_type"), fallback?.type ?? ""),
            model: firstNonEmpty(fieldString(flattened, "c_model"), fieldDisplayString(flattened, "cmdb_model_id"), fallback?.model ?? ""),
            number: firstNonEmpty(fieldString(flattened, "number"), fallback?.number ?? ""),
            location: firstNonEmpty(fieldDisplayString(flattened, "company_location"), fallback?.location ?? ""),
            owner: firstNonEmpty(fieldDisplayString(flattened, "owner"), fallback?.owner ?? ""),
            receivedAt: receivedAt,
            receivedAtDate: officeEquipmentDate(receivedAt) ?? fallback?.receivedAtDate,
            alternativeName: firstNonEmpty(fieldString(flattened, "c_alternative_name"), fallback?.alternativeName ?? ""),
            additionalInformation: firstNonEmpty(fieldString(flattened, "c_additional_info"), fallback?.additionalInformation ?? ""),
            description: firstNonEmpty(fieldString(flattened, "description"), fallback?.description ?? ""),
            detailSections: details.isEmpty ? (fallback?.detailSections ?? []) : details
        )
    }

    private func officeEquipmentSections(from item: [String: Any]) -> [OfficeEquipmentSection] {
        guard let sections = item["sections"] as? [[String: Any]] else { return [] }
        return sections.enumerated().compactMap { sectionIndex, section in
            guard let elements = section["elements"] as? [[String: Any]] else { return nil }
            let fields = elements.enumerated().compactMap { fieldIndex, element -> OfficeEquipmentField? in
                guard officeEquipmentBoolean(element["hidden"]) != true,
                      element["split"] == nil,
                      element["widget_instance_id"] == nil,
                      let rawValue = element["value"] else { return nil }
                let systemName = firstNonEmpty(
                    stringValue(element["sys_column_name"]),
                    stringValue(element["system_name"]),
                    "\(sectionIndex)-\(fieldIndex)"
                )
                var title = stringValue(element["name"])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                if systemName == "sys_updated_at" || title.localizedCaseInsensitiveCompare("Когда изменено") == .orderedSame {
                    title = "Получено"
                }
                guard !title.isEmpty else { return nil }
                let value: String
                if stringValue(element["column_type"]) == "boolean",
                   let boolean = officeEquipmentBoolean(rawValue) {
                    value = boolean ? "Да" : "Нет"
                } else {
                    value = officeEquipmentPlainText(fieldValueString(rawValue, preferDisplay: true))
                }
                guard !value.isEmpty else { return nil }
                return OfficeEquipmentField(
                    systemName: "\(systemName)|\(sectionIndex)-\(fieldIndex)",
                    title: title,
                    value: value
                )
            }
            guard !fields.isEmpty else { return nil }
            let title = firstNonEmpty(stringValue(section["name"]), "Информация")
                .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            return OfficeEquipmentSection(id: "\(sectionIndex)|\(title)", title: title, fields: fields)
        }
    }
}
private func officeEquipmentConditionValue(_ raw: String) -> String {
    raw.replacingOccurrences(of: "^", with: " ")
        .replacingOccurrences(of: "(", with: " ")
        .replacingOccurrences(of: ")", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func officeEquipmentUniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert(officeEquipmentSearchText($0)).inserted }
}

private func officeEquipmentSearchText(_ raw: String) -> String {
    raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
        .lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func officeEquipmentDate(_ raw: String) -> Date? {
    let formats = ["yyyy-MM-dd HH:mm:ss", "dd.MM.yyyy HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}

private func officeEquipmentBoolean(_ raw: Any?) -> Bool? {
    switch raw {
    case let value as Bool: value
    case let value as NSNumber: value.intValue != 0
    case let value as String:
        ["1", "true", "yes"].contains(value.lowercased()) ? true
            : (["0", "false", "no"].contains(value.lowercased()) ? false : nil)
    case let value as [String: Any]: officeEquipmentBoolean(value["value"] ?? value["database_value"])
    default: nil
    }
}

private func officeEquipmentPlainText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "_x000D_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
