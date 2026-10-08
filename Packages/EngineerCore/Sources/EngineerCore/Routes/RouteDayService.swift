import Foundation

public enum RouteDayServiceError: LocalizedError {
    case unauthorized, notFound
    case infrastructure(String)
    case http(status: Int, message: String?)
    case invalidResponse(String)
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Требуется авторизация."
        case .notFound: "Эндпоинт маршрутов не найден."
        case .infrastructure(let message), .invalidResponse(let message): message
        case .http(let status, let message): message ?? "Запрос не выполнен: HTTP \(status)"
        }
    }
    public var shouldQueue: Bool {
        switch self {
        case .infrastructure: true
        case .http(let status, _): [0, 502, 503, 504].contains(status)
        default: false
        }
    }
}

public protocol RouteDayServing {
    func fetchDay(date: String, workType: RouteWorkType, settings: RouteSettings) async throws -> RouteDayRecord?
    func fetchAllDays(settings: RouteSettings) async throws -> [RouteDayRecord]
    func sendDay(_ record: RouteDayRecord, date: String, settings: RouteSettings) async throws -> RouteDayRecord
    func fetchOfficeAddresses() async throws -> [String]
}

public struct RouteDayService: RouteDayServing {
    private let config: AppConfig
    private let authToken: String?
    private let session: URLSession
    public init(config: AppConfig, authToken: String? = nil, session: URLSession? = nil) {
        self.config = config; self.authToken = authToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func fetchDay(date: String, workType: RouteWorkType, settings: RouteSettings) async throws -> RouteDayRecord? {
        let json = try await request(url(from: date, to: date, workType: workType))
        try validateCollection(json)
        return RouteWire.normalizeRemoteDay(RouteWire.extractDay(from: json, date: date, workType: workType), date: date, fallbackWorkType: workType, settings: settings)
    }
    public func fetchAllDays(settings: RouteSettings) async throws -> [RouteDayRecord] {
        let json = try await request(url())
        try validateCollection(json)
        return RouteWire.normalizeRemoteDays(from: json, settings: settings).sorted { ($0.date, $0.workType.rawValue) < ($1.date, $1.workType.rawValue) }
    }
    public func fetchOfficeAddresses() async throws -> [String] {
        let json = try await request(url(path: "/api/v2/offices"))
        guard let dictionary = json as? [String: Any], let offices = dictionary["offices"] as? [[String: Any]] else {
            throw RouteDayServiceError.invalidResponse("Сервер вернул неизвестный список отделений.")
        }
        var seen = Set<String>()
        return offices.compactMap { $0["address"] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func sendDay(_ record: RouteDayRecord, date: String, settings: RouteSettings) async throws -> RouteDayRecord {
        let payload = RouteWire.buildSendPayload(record: record, date: date)
        do {
            let json = try await request(url(), method: "POST", body: payload)
            if let remote = json as? [String: Any], matches(remote, payload: payload),
               let normalized = RouteWire.normalizeRemoteDay(remote, date: date, fallbackWorkType: record.workType, settings: settings) {
                return normalized
            }
            // A 204 cannot reconcile server IDs. Confirm through the existing GET, never repeat POST here.
            return try await readBack(record, date: date, payload: payload, settings: settings)
        } catch let submissionError as RouteDayServiceError where submissionError.shouldQueue {
            do { return try await readBack(record, date: date, payload: payload, settings: settings) }
            catch is CancellationError { throw CancellationError() }
            catch RouteDayServiceError.unauthorized { throw RouteDayServiceError.unauthorized }
            catch { throw submissionError }
        }
    }
    private func readBack(_ record: RouteDayRecord, date: String, payload: [String: Any], settings: RouteSettings) async throws -> RouteDayRecord {
        let json = try await request(url(from: date, to: date, workType: record.workType))
        guard let raw = RouteWire.extractDay(from: json, date: date, workType: record.workType), matches(raw, payload: payload),
              let result = RouteWire.normalizeRemoteDay(raw, date: date, fallbackWorkType: record.workType, settings: settings) else {
            throw RouteDayServiceError.invalidResponse("Не удалось подтвердить отправку маршрута. Обновите данные перед повторной отправкой.")
        }
        return result
    }
    private func matches(_ remote: [String: Any], payload: [String: Any]) -> Bool {
        guard stringValue(remote["date"]) == stringValue(payload["date"]),
              RouteWire.remoteWorkType(remote).rawValue == stringValue(payload["workType"]),
              intValue(remote["distanceKm"]) == intValue(payload["distanceKm"]),
              intValue(remote["periodStartOdometer"]) == intValue(payload["periodStartOdometer"]),
              let actual = remote["stops"] as? [[String: Any]], let expected = payload["stops"] as? [[String: Any]], actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { raw, sent in
            guard var stop = RouteWire.normalizeRemoteStop(raw), let planned = RouteWire.normalizeRemoteStop(sent) else { return false }
            stop.id = planned.id
            return stop == planned
        }
    }
    private func validateCollection(_ json: Any?) throws {
        if json is [Any] { return }
        if let value = json as? [String: Any], value["records"] is [Any] || value["days"] is [String: Any] { return }
        if let value = json as? [String: Any], !value.isEmpty,
           value.keys.allSatisfy({ $0.range(of: #"^\d{4}-\d{2}-\d{2}(\|ARM)?$"#, options: .regularExpression) != nil }) { return }
        throw RouteDayServiceError.invalidResponse("Сервер вернул неизвестный список маршрутов.")
    }
    private func url(path: String = "/api/v2/routes", from: String? = nil, to: String? = nil, workType: RouteWorkType? = nil) throws -> URL {
        let origin = try AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? path : parts.path + path
        parts.queryItems = [("from", from), ("to", to), ("workType", workType?.rawValue)]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        guard let result = parts.url else { throw RouteDayServiceError.invalidResponse("Не настроен адрес сервера.") }
        return result
    }
    private func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        guard let authToken, !authToken.isEmpty else { throw RouteDayServiceError.unauthorized }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        AppBuildIdentity.apply(to: &request)
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        NetworkDiagnostics.logRequest(request, body: nil)
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if AppErrorClassification.isCancellation(error) { throw CancellationError() }
            let message: String
            if case .network(let kind) = AppErrorClassification.classification(for: error) { message = kind.message }
            else { message = "Не удалось выполнить сетевой запрос." }
            throw RouteDayServiceError.infrastructure(message)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RouteDayServiceError.invalidResponse("Сервер вернул неизвестный ответ.") }
        NetworkDiagnostics.logResponse(url: url, statusCode: http.statusCode, data: data)
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw RouteDayServiceError.unauthorized
            case 404: throw RouteDayServiceError.notFound
            case 502, 503, 504: throw RouteDayServiceError.infrastructure("Сервер временно недоступен.")
            default:
                let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw RouteDayServiceError.http(status: http.statusCode, message: value?["message"] as? String ?? value?["error"] as? String)
            }
        }
        if data.isEmpty { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw RouteDayServiceError.invalidResponse("Сервер вернул некорректный JSON маршрута.") }
        return json
    }
}
