import Foundation

public protocol SimpleOneRequestsServing: Sendable {
    func fetch(source: SimpleOneRequestSource, userID: String, authKey: String) async throws -> [SimpleOneRequestRecord]
    func fetch(collection: RequestCollection, userID: String, authKey: String) async throws -> [SimpleOneRequestRecord]
    func fetchTimeReports(authKey: String) async throws -> [TimeReportEntry]
    func detail(record: SimpleOneRequestRecord, authKey: String) async throws -> SimpleOneRequestRecord
}

public struct SimpleOneRequestsService: SimpleOneRequestsServing {
    let baseURL: URL
    let session: URLSession
    let query: SimpleOneQueryConfiguration
    static let multicardStatusColumns = ["multicard_state", "multicard_status", "multicard_mk_status", "u_multicard_state", "u_multicard_status", "u_mk_status", "mk_status", "multicard_request_state"]
    static let columns = ["sys_id", "number", "incoming_number", "registered_at", "opened_at", "sys_created_at", "sys_updated_at", "state", "short_description", "assignment_group", "client_service_id.parent", "client_service_id", "multicard_request_type", "itsm_request_type", "multicard_terminal_address", "multicard_name_client", "multicard_merchant_tin", "multicard_tsp_inn", "merchant_tin", "inn_tsp", "multicard_phone_tsp", "multicard_tsp_phone", "multicard_terminal_phone", "multicard_contact_phone", "multicard_phone_client", "multicard_merchant_phone", "multicard_deadline", "resolved_at", "completed_at", "closed_at", "multicard_closing_date", "assigned_user", "assigned_user.c_full_name", "multicard_terminal_model", "multicard_id_terminal", "multicard_pos", "pb_sn_pos_uninstall", "multicard_contact_person", "multicard_comment_ing", "multicard_information", "multicard_additional_information", "additional_information", "description", "new_closure_code", "closure_notes", "multicard_city", "multicard_return_number_pos", "multicard_pin_pad", "multicard_return_number_pin"] + multicardStatusColumns

    public init(config: AppConfig, query: SimpleOneQueryConfiguration = .init(), session: URLSession? = nil) {
        baseURL = AppConfig.configuredURL(config.simpleOneAPIOrigin); self.query = query
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration)
    }
    public func fetch(source: SimpleOneRequestSource, userID: String, authKey: String) async throws -> [SimpleOneRequestRecord] {
        try await fetch(collection: .personal(source), userID: userID, authKey: authKey)
    }
    public func fetch(collection: RequestCollection, userID: String, authKey: String) async throws -> [SimpleOneRequestRecord] {
        let condition = try query.condition(collection: collection, userID: userID) + "^ORDERBYDESCsys_updated_at^ORDERBYDESCsys_id"
        let items = try await fetchAllRows(table: "itsm_request", condition: condition, columns: Self.columns, authKey: authKey)
        return try items.map { item in
            let record = makeRequestRecord(from: item, source: collection.source)
            guard !record.number.isEmpty else { throw SimpleOneServiceError.invalidResponse }
            return record
        }.filter { record in
            if collection == .personal(.closed) { return RequestsPolicy.includedInArchive(record) }
            if collection == .returnEquipment { return isCoordinationReturnEquipmentRequestType(record.requestType) }
            return true
        }.sorted {
            if $0.primaryDate != $1.primaryDate { return $0.primaryDate > $1.primaryDate }
            return $0.number.localizedStandardCompare($1.number) == .orderedDescending
        }
    }
    public func fetchTimeReports(authKey: String) async throws -> [TimeReportEntry] {
        let items = try await fetchAllRows(table: "itsm_tchnsrv_time_report", condition: query.timeReportCondition(), columns: [], authKey: authKey)
        var seen = Set<String>()
        return items.compactMap(makeTimeReportEntry(from:)).filter { seen.insert($0.stableID).inserted }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.activity.localizedStandardCompare($1.activity) == .orderedAscending
        }
    }
    private func fetchAllRows(table: String, condition: String, columns: [String], authKey: String) async throws -> [[String: Any]] {
        var page = 1, rows: [String: [String: Any]] = [:]
        let size = 100
        while true {
            try Task.checkCancellation()
            guard var components = URLComponents(url: baseURL.appendingPathComponent("list/" + table), resolvingAgainstBaseURL: false) else { throw SimpleOneServiceError.invalidURL }
            components.queryItems = [URLQueryItem(name: "condition", value: condition), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: String(size))]
            if !columns.isEmpty { components.queryItems?.append(URLQueryItem(name: "columns", value: columns.joined(separator: ","))) }
            guard let url = components.url else { throw SimpleOneServiceError.invalidURL }
            let response = try await request(url: url, authKey: authKey)
            guard let items = listItems(response) else { throw SimpleOneServiceError.invalidResponse }
            let previous = rows.count
            for item in items {
                let id = fieldString(item, "sys_id", "id")
                guard !id.isEmpty else { throw SimpleOneServiceError.invalidResponse }
                if let old = rows[id], fieldString(old, "sys_updated_at") > fieldString(item, "sys_updated_at") { continue }
                rows[id] = item
            }
            let total = totalCount(response)
            let hasMore = total.map { page * size < $0 } ?? (items.count == size)
            if !hasMore {
                if let total, rows.count < total { throw SimpleOneServiceError.server("Список изменился во время загрузки. Кеш сохранён; повторите обновление.") }
                break
            }
            guard rows.count > previous else { throw SimpleOneServiceError.server("SimpleOne повторил страницу. Кеш сохранён; повторите обновление.") }
            page += 1
        }
        return Array(rows.values)
    }
    public func detail(record: SimpleOneRequestRecord, authKey: String) async throws -> SimpleOneRequestRecord {
        guard !record.sysID.isEmpty, record.sysID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw SimpleOneServiceError.invalidResponse }
        return try await fetchRequest(sysID: record.sysID, fallback: record, authKey: authKey)
    }
    func request(path: String, authKey: String) async throws -> [String: Any] {
        try await request(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), authKey: authKey)
    }
    private func request(url: URL, authKey: String) async throws -> [String: Any] {
        guard !baseURL.isFileURL else { throw SimpleOneServiceError.invalidURL }
        var request = URLRequest(url: url); request.timeoutInterval = 35; request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("no-cache", forHTTPHeaderField: "Cache-Control"); request.setValue("auth=\(authKey)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SimpleOneServiceError.invalidResponse }
        // Log only the endpoint: list conditions contain user IDs and searches.
        NetworkDiagnostics.logResponse(url: URL(string: url.path, relativeTo: baseURL)?.absoluteURL ?? baseURL, statusCode: response.statusCode, data: data)
        guard response.statusCode != 401 else { throw SimpleOneServiceError.unauthorized }
        guard response.statusCode != 403 else { throw SimpleOneServiceError.forbidden }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SimpleOneServiceError.invalidResponse }
        if let error = serverError(from: json) { throw error }
        guard (200..<300).contains(response.statusCode) else { throw SimpleOneServiceError.server("SimpleOne вернул HTTP \(response.statusCode).") }
        return json
    }
    private func listItems(_ response: [String: Any]) -> [[String: Any]]? {
        let data = response["data"] as? [String: Any]
        for container in [data, response].compactMap({ $0 }) {
            for key in ["items", "list", "records"] { if let items = container[key] as? [[String: Any]] { return items } }
            if let item = container["item"] as? [String: Any] { return [item] }
        }
        return nil
    }
    private func totalCount(_ response: [String: Any]) -> Int? {
        let data = response["data"] as? [String: Any]
        for container in [response, data, response["meta"] as? [String: Any], response["pagination"] as? [String: Any], data?["pagination"] as? [String: Any], data?["meta"] as? [String: Any]].compactMap({ $0 }) {
            for key in ["total", "total_count", "totalCount", "records_total", "recordsTotal"] {
                if let value = container[key], let number = Int(String(describing: value)), number >= 0 { return number }
            }
        }
        return nil
    }
}
