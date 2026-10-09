import Foundation

public enum GsmFuelError: LocalizedError {
    case unauthorized, invalidResponse, busy, conflict, staleSession
    case http(Int, String), infrastructure(String)
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Требуется авторизация."
        case .invalidResponse: "Сервер вернул неизвестный ответ. Обновите данные перед повторной отправкой."
        case .busy: "Операция уже выполняется."
        case .conflict: "Данные изменились. Обновите их перед сохранением."
        case .staleSession: "Сессия изменилась. Откройте раздел снова."
        case .http(let code, let message): "\(message) (HTTP \(code))"
        case .infrastructure(let message): message
        }
    }
}
public protocol GsmFuelServing {
    func fetchFuel() async throws -> [FuelRecord]
    func saveFuel(_ record: FuelRecord) async throws -> FuelRecord
    func deleteFuel(id: String) async throws
    func fetchProfile() async throws -> GsmProfileLoadResult
    func fetchProjects() async throws -> [GsmProjectOption]
    func saveProfile(_ profile: GsmProfile) async throws -> GsmProfileLoadResult
    func sendReport(month: String) async throws -> GsmReportResponse
    func fetchStartOdometer(month: String) async throws -> Int?
}
public struct GsmFuelService: GsmFuelServing {
    private let config: AppConfig
    private let authToken: String?
    private let session: URLSession
    public init(config: AppConfig, authToken: String?, session: URLSession? = nil) {
        self.config = config; self.authToken = authToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }
    public func fetchFuel() async throws -> [FuelRecord] { try FuelWire.records(await request("/api/v2/fuel")) }
    public func saveFuel(_ record: FuelRecord) async throws -> FuelRecord {
        let body = try FuelWire.payload(record)
        let path = try record.id.map { try recordPath($0) } ?? "/api/v2/fuel"
        let raw = try await request(path, method: record.id == nil ? "POST" : "PUT", body: body)
        guard let row = raw as? [String: Any] else { throw GsmFuelError.invalidResponse }
        let saved = try FuelWire.record(row)
        guard let id = saved.id, !id.isEmpty, record.id == nil || record.id == id else { throw GsmFuelError.invalidResponse }
        return saved
    }
    public func deleteFuel(id: String) async throws { _ = try await request(recordPath(id), method: "DELETE", allowEmpty: true) }
    public func fetchProfile() async throws -> GsmProfileLoadResult { try GsmWire.profile(await request("/api/v2/gsm/profile")) }
    public func fetchProjects() async throws -> [GsmProjectOption] { try GsmWire.projects(await request("/api/v2/gsm/projects")) }
    public func saveProfile(_ profile: GsmProfile) async throws -> GsmProfileLoadResult {
        try GsmWire.profile(await request("/api/v2/gsm/profile", method: "PUT", body: GsmWire.profilePayload(profile)))
    }
    public func sendReport(month: String) async throws -> GsmReportResponse {
        let month = month.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GsmWire.isValidMonth(month) else { throw AppServiceError.message("Месяц должен быть в формате YYYY-MM.") }
        let raw = try await request("/api/v2/gsm/report", method: "POST", body: ["month": month], timeout: 60)
        let result = try JSONDecoder().decode(GsmReportResponse.self, from: JSONSerialization.data(withJSONObject: raw as Any))
        guard result.success, result.month == month else { throw GsmFuelError.invalidResponse }
        return result
    }
    public func fetchStartOdometer(month: String) async throws -> Int? {
        guard GsmWire.isValidMonth(month) else { throw AppServiceError.message("Месяц должен быть в формате YYYY-MM.") }
        let raw = try await request("/api/v2/gsm/odometer-suggestion", query: [URLQueryItem(name: "month", value: month)])
        guard let row = raw as? [String: Any], stringValue(row["month"]) == month, row.keys.contains("startOdometer") else { throw GsmFuelError.invalidResponse }
        return intValue(row["startOdometer"])
    }
    private func recordPath(_ id: String) throws -> String {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }) else { throw GsmFuelError.invalidResponse }
        return "/api/v2/fuel/" + id
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem]? = nil, timeout: TimeInterval = 20, allowEmpty: Bool = false) async throws -> Any? {
        guard let authToken, !authToken.isEmpty else { throw GsmFuelError.unauthorized }
        let origin = try AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? path : parts.path + path
        parts.queryItems = query
        guard let url = parts.url else { throw GsmFuelError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        AppBuildIdentity.apply(to: &request)
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        try Task.checkCancellation()
        NetworkDiagnostics.logRequest(request, body: nil)
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if AppErrorClassification.isCancellation(error) { throw CancellationError() }
            throw GsmFuelError.infrastructure("Не удалось выполнить запрос. Если это была отправка, её результат неизвестен; обновите данные перед повтором.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GsmFuelError.invalidResponse }
        NetworkDiagnostics.logResponse(url: url, statusCode: http.statusCode, data: data)
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(http.statusCode) else {
            if [401, 403].contains(http.statusCode) { throw GsmFuelError.unauthorized }
            let row = json as? [String: Any]
            let message = row?["message"] as? String ?? (row?["error"] as? String == "GSM_PROFILE_REQUIRED" ? "Заполните ГСМ профиль в настройках." : row?["error"] as? String) ?? "Ошибка сервера"
            throw GsmFuelError.http(http.statusCode, message)
        }
        if data.isEmpty, allowEmpty { return nil }
        guard let json else { throw GsmFuelError.invalidResponse }
        return json
    }
}
