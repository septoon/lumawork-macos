import Foundation

public struct BackpackService {
    private let simpleOneService: SimpleOneRequestsService
    private let query: SimpleOneQueryConfiguration
    public init(config: AppConfig, query: SimpleOneQueryConfiguration = .init()) { self.query = query; simpleOneService = SimpleOneRequestsService(config: config, query: query) }
    private var condition: String {
        get throws {
        let currentUserDynamicID = try query.required("SIMPLEONE_CURRENT_USER_DYNAMIC_ID")
        let writeOffDynamicID = try query.required("SIMPLEONE_WRITE_OFF_DYNAMIC_ID")
        return "(quantity>0^(warehouse.responsible_for_write_offCONTAINS_DYNAMIC\(writeOffDynamicID)^ORactivity.service_managerDYNAMIC\(currentUserDynamicID)^ORactivity.balance_management_managersCONTAINS_DYNAMIC\(writeOffDynamicID)^ORactivity.project_managerDYNAMIC\(currentUserDynamicID)))"
        }
    }

    public func fetchItems(authKey: String) async throws -> [BackpackItem] {
        var page = 1
        let perPage = 100
        var items: [BackpackItem] = []
        var seenIDs = Set<String>()

        while true {
            try Task.checkCancellation()
            let previousCount = items.count
            let pageItems = try await fetchItemsPage(
                page: page,
                perPage: perPage,
                authKey: authKey
            )
            for item in pageItems.items {
                guard seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }

            guard pageItems.hasMore else { break }
            guard items.count > previousCount else { throw SimpleOneServiceError.invalidResponse }
            page += 1
        }

        return items.sorted { lhs, rhs in
            switch (lhs.receivedAtDate, rhs.receivedAtDate) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.serialNumber.localizedStandardCompare(rhs.serialNumber) == .orderedAscending
        }
    }

    private func fetchItemsPage(
        page: Int,
        perPage: Int,
        authKey: String
    ) async throws -> (items: [BackpackItem], hasMore: Bool) {
        guard var components = URLComponents(
            url: simpleOneService.baseURL.appendingPathComponent("list/itsm_tchnsrv_balances_in_warehouses"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SimpleOneServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "condition", value: try condition),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        guard let url = components.url else {
            throw SimpleOneServiceError.invalidURL
        }

        let response = try await simpleOneService.request(url: url, authKey: authKey)
        guard let records = simpleOneService.listItems( response) else {
            throw simpleOneService.serverError(from: response) ?? SimpleOneServiceError.invalidResponse
        }

        let items = records.map(makeItem(from:)).filter { !$0.name.isEmpty || !$0.serialNumber.isEmpty }
        let hasMore = simpleOneService.totalCount(response).map { page * perPage < $0 } ?? (records.count == perPage)
        return (items, hasMore)
    }

    private func makeItem(from raw: [String: Any]) -> BackpackItem {
        let sysID = fieldString(raw, "sys_id", "id")
        let searchCode = fieldString(raw, "Код поиска ЗИП", "search_code", "code", "name")
        let name = firstNonEmpty(
            fieldDisplayString(raw, "ЗИП.Наименование"),
            fieldDisplayString(raw, "zip.name", "zip_id.name", "spare_part.name", "spare.name"),
            fieldString(raw, "zip.name", "zip_id.name", "spare_part.name", "spare.name", "item.name")
        )
        let serialNumber = firstNonEmpty(
            fieldString(raw, "ЗИП.S/N"),
            fieldString(raw, "zip.s_n", "zip_id.s_n", "spare_part.s_n"),
            fieldString(raw, "zip.serial_number", "zip_id.serial_number", "spare_part.serial_number"),
            fieldString(raw, "serial_number", "sn", "s/n", "s_n", "serial")
        )
        let responsible = firstNonEmpty(
            fieldDisplayString(raw, "Склад.Ответственные за списание"),
            fieldDisplayString(raw, "warehouse.responsible_for_write_off"),
            fieldString(raw, "warehouse.responsible_for_write_off", "responsible_for_write_off")
        )
        let receivedAt = backpackReceivedAt(from: raw)
        let quantity = backpackQuantity(from: raw)
        let id = firstNonEmpty(sysID, searchCode, [name, serialNumber, responsible].joined(separator: "|"))

        return BackpackItem(
            id: id,
            name: normalizedBackpackValue(name),
            serialNumber: normalizedBackpackValue(serialNumber),
            responsible: normalizedBackpackValue(responsible),
            receivedAt: normalizedBackpackValue(receivedAt.text),
            receivedAtDate: receivedAt.date,
            quantity: quantity
        )
    }

    @MainActor public func hydrateItems(
        _ items: [BackpackItem],
        cachedItems: [BackpackItem],
        authKey: String,
        onItem: @MainActor @Sendable (BackpackItem) -> Void
    ) async throws {
        let cachedByID = Dictionary(cachedItems.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let pending = items.filter { item in
            guard let cached = cachedByID[item.id],
                  let version = item.receivedAtDate,
                  version == cached.receivedAtDate,
                  item.name == cached.name,
                  item.serialNumber == cached.serialNumber,
                  item.responsible == cached.responsible,
                  item.quantity == cached.quantity else { return true }
            onItem(cached)
            return false
        }
        try await withThrowingTaskGroup(of: BackpackItem.self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ item: BackpackItem) {
                group.addTask {
                    try Task.checkCancellation()
                    guard !item.id.isEmpty else {
                        return item
                    }

                    do {
                        return try await fetchDetailedItem(item, authKey: authKey)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch SimpleOneServiceError.forbidden {
                        throw SimpleOneServiceError.forbidden
                    } catch SimpleOneServiceError.unauthorized {
                        throw SimpleOneServiceError.unauthorized
                    } catch {
                        if let cached = cachedByID[item.id],
                           item.name == cached.name,
                           item.serialNumber == cached.serialNumber,
                           item.responsible == cached.responsible,
                           item.quantity == cached.quantity {
                            return cached
                        }
                        return item
                    }
                }
            }

            for _ in 0..<min(4, pending.count) {
                if let item = iterator.next() { enqueue(item) }
            }
            while let item = try await group.next() {
                onItem(item)
                if let nextItem = iterator.next() { enqueue(nextItem) }
            }
        }
    }

    private func fetchDetailedItem(_ item: BackpackItem, authKey: String) async throws -> BackpackItem {
        let response = try await simpleOneService.request(
            path: "/record/itsm_tchnsrv_balances_in_warehouses/\(item.id)",
            authKey: authKey
        )
        guard let record = simpleOneService.recordItem(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        let flattened = flattenedRecordItem(from: record)
        let detailItem = makeItem(from: flattened)

        return BackpackItem(
            id: item.id,
            name: detailItem.name == "(не задано)" ? item.name : detailItem.name,
            serialNumber: detailItem.serialNumber == "(не задано)" ? item.serialNumber : detailItem.serialNumber,
            responsible: detailItem.responsible == "(не задано)" ? item.responsible : detailItem.responsible,
            receivedAt: detailItem.receivedAt == "(не задано)" ? item.receivedAt : detailItem.receivedAt,
            receivedAtDate: detailItem.receivedAtDate ?? item.receivedAtDate,
            quantity: detailItem.quantity > 0 ? detailItem.quantity : item.quantity
        )
    }

    private func flattenedRecordItem(from item: [String: Any]) -> [String: Any] {
        guard let sections = item["sections"] as? [[String: Any]] else {
            return item
        }

        var flattened = item
        for section in sections {
            guard let elements = section["elements"] as? [[String: Any]] else { continue }
            for element in elements {
                guard let value = element["value"] else { continue }

                for keyName in ["sys_column_name", "system_name", "name"] {
                    guard let key = element[keyName] as? String, !key.isEmpty else { continue }
                    if fieldString(flattened, key).isEmpty {
                        setFieldValue(value, for: key, in: &flattened)
                    }
                }
            }
        }
        return flattened
    }
}

private func normalizedBackpackValue(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "(не задано)" : trimmed
}

private func normalizedBackpackSearchText(_ raw: String) -> String {
    raw
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func backpackQuantity(from raw: [String: Any]) -> Int {
    let value = firstNonEmpty(
        fieldString(raw, "Остаток", "Количество"),
        fieldString(raw, "quantity")
    )
    let normalized = value.replacingOccurrences(of: ",", with: ".")
    return Double(normalized).map { max(Int($0), 0) } ?? 0
}

private func backpackReceivedAt(from raw: [String: Any]) -> (text: String, date: Date?) {
    let value = firstNonEmpty(
        fieldString(raw, "Когда изменено"),
        fieldString(raw, "sys_updated_at", "updated_at")
    )
    guard !value.isEmpty else {
        return ("", nil)
    }

    guard let date = BackpackDateFormatters.input.date(from: value) else {
        return (value, nil)
    }
    return (BackpackDateFormatters.output.string(from: date), date)
}

private enum BackpackDateFormatters {
    static let input: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let output: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()
}
