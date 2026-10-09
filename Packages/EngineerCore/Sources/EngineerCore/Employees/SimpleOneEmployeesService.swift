import Foundation

extension SimpleOneRequestsService {
    public func fetchEmployeeAddressOptions(
        query: String,
        authKey: String
    ) async throws -> [SimpleOneEmployeeAddress] {
        let normalizedQuery = simpleOneEmployeeConditionValue(query)
        guard normalizedQuery.count >= 2 else { return [] }

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/itsm_tchnsrv_tgr"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: "(localityLIKE\(normalizedQuery))"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: "40")
        ]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await request(url: url, authKey: authKey)
        guard let items = listItems( response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        var seenIDs = Set<String>()
        return items
            .compactMap(makeEmployeeAddress(from:))
            .filter { seenIDs.insert($0.sysID).inserted }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    public func fetchEmployees(
        address: SimpleOneEmployeeAddress,
        searchText: String,
        authKey: String,
        perPage: Int = 100
    ) async throws -> (employees: [SimpleOneEmployee], totalCount: Int) {
        let condition = employeeCondition(
            addressID: address.sysID,
            searchText: searchText
        )
        var page = 1
        var employees: [SimpleOneEmployee] = []
        var seenIDs = Set<String>()
        var expectedTotal = 0

        while true {
            let response = try await fetchEmployeeListPage(
                condition: condition,
                page: page,
                perPage: perPage,
                authKey: authKey
            )
            expectedTotal = response.totalCount ?? expectedTotal

            let previousCount = employees.count
            for item in response.items {
                let employee = makeEmployee(from: item, fallbackAddress: address)
                guard !employee.sysID.isEmpty, seenIDs.insert(employee.sysID).inserted else {
                    continue
                }
                employees.append(employee)
            }

            let hasMore = response.totalCount.map { page * perPage < $0 }
                ?? (response.items.count == perPage)
            guard hasMore else { break }
            guard employees.count > previousCount else { throw SimpleOneServiceError.invalidResponse }
            page += 1
        }

        employees.sort {
            $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
        }
        return (employees, max(expectedTotal, employees.count))
    }

    public func fetchEmployeeDetail(
        sysID: String,
        fallback: SimpleOneEmployee? = nil,
        authKey: String
    ) async throws -> SimpleOneEmployee {
        guard !sysID.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }

        let response = try await request(
            path: "/record/employee/\(sysID)",
            authKey: authKey
        )
        guard let item = recordItem(from: response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        let flattened = flattenedRecordItem(from: item)
        var employee = makeEmployee(
            from: flattened,
            fallbackAddress: fallback?.address
        )
        employee.sysID = firstNonEmpty(employee.sysID, fallback?.sysID ?? sysID)
        employee.displayName = firstNonEmpty(
            fieldString(flattened, "c_fio"),
            employee.displayName,
            fallback?.displayName ?? ""
        )
        employee.firstName = firstNonEmpty(employee.firstName, fallback?.firstName ?? "")
        employee.lastName = firstNonEmpty(employee.lastName, fallback?.lastName ?? "")
        employee.middleName = firstNonEmpty(employee.middleName, fallback?.middleName ?? "")
        employee.login = firstNonEmpty(employee.login, fallback?.login ?? "")
        employee.email = firstNonEmpty(employee.email, fallback?.email ?? "")
        employee.position = firstNonEmpty(employee.position, fallback?.position ?? "")
        employee.manager = firstNonEmpty(employee.manager, fallback?.manager ?? "")
        employee.company = firstNonEmpty(employee.company, fallback?.company ?? "")
        employee.department = firstNonEmpty(employee.department, fallback?.department ?? "")
        employee.phone = firstNonEmpty(employee.phone, fallback?.phone ?? "")
        employee.updatedAt = firstNonEmpty(employee.updatedAt, fallback?.updatedAt ?? "")
        employee.detailSections = makeEmployeeDetailSections(from: item)
        return employee
    }

    private func fetchEmployeeListPage(
        condition: String,
        page: Int,
        perPage: Int,
        authKey: String
    ) async throws -> (items: [[String: Any]], totalCount: Int?) {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/employee"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await request(url: url, authKey: authKey)
        guard let items = listItems( response) else {
            throw serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }
        return (items, totalCount( response))
    }

    private func employeeCondition(addressID: String, searchText: String) -> String {
        var parts = ["c_tgr=\(addressID)"]
        let query = simpleOneEmployeeConditionValue(searchText)
        if !query.isEmpty {
            parts.append("keywordsARE\(query)")
        }
        return "(\(parts.joined(separator: "^")))"
    }

    private func makeEmployee(
        from item: [String: Any],
        fallbackAddress: SimpleOneEmployeeAddress?
    ) -> SimpleOneEmployee {
        let firstName = fieldString(item, "first_name")
        let lastName = fieldString(item, "last_name")
        let middleName = fieldString(item, "middle_name")
        let assembledName = [lastName, firstName, middleName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let address = makeEmployeeAddress(
            id: employeeFieldDatabaseString(item, key: "c_tgr"),
            title: fieldDisplayString(item, "c_tgr"),
            region: fieldDisplayString(item, "c_tgr.regions"),
            federalRegion: fieldDisplayString(item, "c_tgr.federal_region")
        ) ?? fallbackAddress

        return SimpleOneEmployee(
            sysID: firstNonEmpty(
                stringValue(item["sys_id"]),
                fieldString(item, "sys_id")
            ),
            displayName: firstNonEmpty(
                fieldString(item, "c_fio"),
                assembledName,
                fieldString(item, "__display_value")
            ),
            firstName: firstName,
            lastName: lastName,
            middleName: middleName,
            login: fieldString(item, "username"),
            email: fieldString(item, "email"),
            position: fieldDisplayString(item, "c_position_id"),
            manager: fieldDisplayString(item, "manager"),
            company: fieldDisplayString(item, "company"),
            department: fieldDisplayString(item, "department"),
            phone: fieldString(item, "mobile_phone"),
            address: address,
            isActive: employeeBoolValue(fieldRawValue(item, "active")),
            isLocked: employeeBoolValue(fieldRawValue(item, "locked_out")),
            updatedAt: fieldString(item, "sys_updated_at"),
            detailSections: []
        )
    }

    private func makeEmployeeAddress(from item: [String: Any]) -> SimpleOneEmployeeAddress? {
        makeEmployeeAddress(
            id: firstNonEmpty(
                stringValue(item["sys_id"]),
                fieldString(item, "sys_id")
            ),
            title: firstNonEmpty(
                fieldString(item, "locality"),
                fieldString(item, "__display_value")
            ),
            region: fieldDisplayString(item, "regions"),
            federalRegion: fieldDisplayString(item, "federal_region")
        )
    }

    private func makeEmployeeAddress(
        id: String,
        title: String,
        region: String,
        federalRegion: String
    ) -> SimpleOneEmployeeAddress? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedTitle.isEmpty else { return nil }
        return SimpleOneEmployeeAddress(
            sysID: trimmedID,
            title: trimmedTitle,
            region: region,
            federalRegion: federalRegion
        )
    }

    private func makeEmployeeDetailSections(
        from item: [String: Any]
    ) -> [SimpleOneEmployeeSection] {
        guard let sections = item["sections"] as? [[String: Any]] else {
            return []
        }

        return sections.enumerated().compactMap { sectionIndex, section in
            guard let elements = section["elements"] as? [[String: Any]] else {
                return nil
            }
            let fields = elements.enumerated().compactMap { fieldIndex, element in
                employeeDetailField(
                    from: element,
                    fallbackID: "\(sectionIndex)-\(fieldIndex)"
                )
            }
            guard !fields.isEmpty else { return nil }
            let rawTitle = firstNonEmpty(
                stringValue(section["name"]),
                stringValue(section["title"]),
                "Информация"
            )
            return SimpleOneEmployeeSection(
                id: "\(sectionIndex)|\(rawTitle)",
                title: rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "* ")),
                fields: fields
            )
        }
    }

    private func employeeDetailField(
        from element: [String: Any],
        fallbackID: String
    ) -> SimpleOneEmployeeField? {
        guard employeeBoolValue(element["hidden"]) != true else { return nil }

        let columnName = stringValue(element["sys_column_name"])
        let title = stringValue(element["name"])
            .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        guard !title.isEmpty,
              columnName != "password_hash",
              title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != "пароль",
              let rawValue = element["value"] else {
            return nil
        }

        let type = stringValue(element["column_type"])
        let value: String
        if type == "boolean", let boolean = employeeBoolValue(rawValue) {
            value = boolean ? "Да" : "Нет"
        } else {
            value = fieldValueString(rawValue, preferDisplay: true)
        }
        let cleanedValue = employeePlainText(value)
        guard !cleanedValue.isEmpty else { return nil }

        let baseSystemName = firstNonEmpty(
            stringValue(element["system_name"]),
            columnName,
            fallbackID
        )
        return SimpleOneEmployeeField(
            systemName: "\(baseSystemName)|\(fallbackID)",
            title: title,
            value: cleanedValue
        )
    }
}

private func simpleOneEmployeeConditionValue(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "^", with: " ")
        .replacingOccurrences(of: "(", with: " ")
        .replacingOccurrences(of: ")", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func employeeBoolValue(_ raw: Any?) -> Bool? {
    switch raw {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.intValue != 0
    case let value as String:
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    case let value as [String: Any]:
        return employeeBoolValue(value["value"] ?? value["database_value"])
    default:
        return nil
    }
}

private func employeeFieldDatabaseString(
    _ item: [String: Any],
    key: String
) -> String {
    employeeDatabaseString(fieldRawValue(item, key))
}

private func employeeDatabaseString(_ raw: Any?) -> String {
    if raw is NSNull { return "" }
    if let string = raw as? String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let number = raw as? NSNumber {
        return number.stringValue
    }
    if let dictionary = raw as? [String: Any] {
        if let value = dictionary["value"] {
            let nestedValue = employeeDatabaseString(value)
            if !nestedValue.isEmpty { return nestedValue }
        }
        let databaseValue = stringValue(dictionary["database_value"])
        if !databaseValue.isEmpty { return databaseValue }
        return stringValue(dictionary["display_value"])
    }
    return ""
}

private func employeePlainText(_ raw: String) -> String {
    raw
        .replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
