import Foundation

// Authenticated domain requests share redaction, cookie isolation and exact HTTP errors.
struct DomainHTTPClient {
    let config: AppConfig
    let token: String
    private let client: HTTPClient
    init(config: AppConfig, token: String) {
        self.config = config; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        client = HTTPClient(session: URLSession(configuration: configuration))
    }
    func request(_ path: String, method: String = "GET", body: Any? = nil, timeout: TimeInterval = 20) async throws -> Any? {
        guard !token.isEmpty else { throw GsmFuelError.unauthorized }
        let origin = try AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        return try await client.request(origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                                        method: method, body: body, authToken: token, redactDiagnostics: true, timeout: timeout).json
    }
    func decode<T: Decodable>(_ type: T.Type, json: Any?) throws -> T {
        guard let json else { throw GsmFuelError.invalidResponse }
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json)) }
        catch { throw GsmFuelError.invalidResponse }
    }
    static func id(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw GsmFuelError.invalidResponse }
        return value
    }
    static func isUncertain(_ error: Error) -> Bool {
        if case AppServiceError.http(let status, _) = error, let status, (400..<500).contains(status), status != 408 { return false }
        return true
    }
    static func isUnauthorized(_ error: Error) -> Bool {
        if case AppServiceError.http(let status, _) = error { return status == 401 || status == 403 }
        if case GsmFuelError.unauthorized = error { return true }
        return false
    }
}
