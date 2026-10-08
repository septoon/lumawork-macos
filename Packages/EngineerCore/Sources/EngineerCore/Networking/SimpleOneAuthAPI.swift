import Foundation

public struct SimpleOneAuthAPI: SimpleOneAuthenticating {
    private let baseURL: URL
    private let session: URLSession

    public init(config: AppConfig, session: URLSession? = nil) {
        baseURL = AppConfig.configuredURL(config.simpleOneAPIOrigin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // Only the explicit auth key belongs to this session. Never accept shared cookies.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func login(username: String, password: String) async throws -> String {
        let response = try await request(path: "auth/login", method: "POST", body: ["username": username, "password": password, "language": "ru"])
        guard let data = response["data"] as? [String: Any],
              let key = data["auth_key"] as? String, !key.isEmpty else {
            throw SimpleOneServiceError.invalidResponse
        }
        return key
    }

    public func currentUser(authKey: String) async throws -> SimpleOneUser {
        let response = try await request(path: "user/me", authKey: authKey)
        guard let data = response["data"] as? [String: Any] else { throw SimpleOneServiceError.invalidResponse }
        func value(_ key: String) -> String {
            guard let raw = data[key], !(raw is NSNull) else { return "" }
            return raw as? String ?? String(describing: raw)
        }
        let user = SimpleOneUser(sysID: value("sys_id"), username: value("username"), firstName: value("first_name"), lastName: value("last_name"))
        guard !user.sysID.isEmpty else { throw SimpleOneServiceError.invalidResponse }
        return user
    }

    private func request(path: String, method: String = "GET", body: [String: String]? = nil, authKey: String? = nil) async throws -> [String: Any] {
        guard !baseURL.isFileURL else { throw SimpleOneServiceError.invalidURL }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let authKey { request.setValue("auth=\(authKey)", forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Auth diagnostics contain only method/path/status, never login, password or cookie.
        NetworkDiagnostics.logRequest(request, body: nil)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            NetworkDiagnostics.logError(url: request.url ?? baseURL, method: method, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw SimpleOneServiceError.invalidResponse }
        NetworkDiagnostics.logResponse(url: request.url ?? baseURL, statusCode: http.statusCode, data: data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json.flatMap(Self.serverMessage)
        let isLogin = path == "auth/login"
        guard http.statusCode != 401 else {
            throw isLogin ? SimpleOneServiceError.invalidCredentials : SimpleOneServiceError.unauthorized
        }
        guard http.statusCode != 403 else { throw SimpleOneServiceError.forbidden }
        // This upstream reports bad login credentials as HTTP500 + an ERROR envelope.
        if let message, Self.isCredentialRefusal(message) {
            throw isLogin ? SimpleOneServiceError.invalidCredentials : SimpleOneServiceError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let explanation = message.map { " \($0)" } ?? ""
            throw SimpleOneServiceError.server("SimpleOne вернул HTTP \(http.statusCode)." + explanation)
        }
        guard let json else { throw SimpleOneServiceError.invalidResponse }
        if let message { throw SimpleOneServiceError.server(message) }
        return json
    }
    private static func serverMessage(_ response: [String: Any]) -> String? {
        if response["status"] as? String == "OK" { return nil }
        if let errors = response["errors"] as? [[String: Any]],
           let message = errors.compactMap({ $0["message"] as? String }).first(where: { !$0.isEmpty }) { return message }
        for key in ["message", "error"] {
            if let message = response[key] as? String, !message.isEmpty { return message }
        }
        return nil
    }

    private static func isCredentialRefusal(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("credentials") || message.localizedCaseInsensitiveContains("wrong username or password")
    }
}

public enum SimpleOneServiceError: LocalizedError {
    case missingCredentials, unauthorized, invalidCredentials, forbidden, invalidResponse, invalidURL
    case server(String)
    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "Войдите в SimpleOne, чтобы загрузить заявки."
        case .unauthorized: "Сессия SimpleOne истекла. Войдите снова."
        case .invalidCredentials: "Неверный логин или пароль SimpleOne."
        case .forbidden: "SimpleOne вернул HTTP 403."
        case .invalidResponse: "SimpleOne вернул неожиданный ответ."
        case .invalidURL: "Не удалось собрать URL запроса SimpleOne."
        case .server(let message): message
        }
    }
}
