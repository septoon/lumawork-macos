import Foundation

public struct LumaWorkAuthAPI {
    private let baseURL: URL
    private let session: URLSession

    public init(config: AppConfig, session: URLSession? = nil) {
        self.baseURL = AppConfig.configuredURL(config.lumaWorkAPIOrigin)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func requestCode(email: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/auth/request-code",
            method: "POST",
            body: ["email": email]
        )
    }

    public func verifyCode(email: String, code: String) async throws -> AppSession {
        try await request(
            path: "/auth/verify-code",
            method: "POST",
            body: ["email": email, "code": code]
        )
    }

    public func currentUser(token: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/me",
            token: token,
            timeoutInterval: 8,
            maxAttempts: 1
        )
        return response.user
    }

    public func logout(token: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/auth/logout",
            method: "POST",
            token: token
        )
    }

    public func uploadAvatar(token: String, imageData: Data, mimeType: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile/avatar",
            method: "POST",
            body: [
                "imageBase64": imageData.base64EncodedString(),
                "mimeType": mimeType
            ],
            token: token
        )
        return response.user
    }

    public func deleteAvatar(token: String) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile/avatar",
            method: "DELETE",
            token: token
        )
        return response.user
    }

    public func saveProfile(token: String, profile: UserProfileData) async throws -> AppUser {
        let response: CurrentUserResponse = try await request(
            path: "/api/v2/profile",
            method: "PUT",
            body: profile.requestBody,
            token: token
        )
        return response.user
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: String]? = nil,
        token: String? = nil,
        timeoutInterval: TimeInterval = 45,
        maxAttempts: Int = 2
    ) async throws -> Response {
        guard !baseURL.isFileURL else {
            throw AppServiceError.message("Не настроен адрес сервера.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AppBuildIdentity.apply(to: &request)

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            NetworkDiagnostics.logRequest(request, body: body)
            (data, urlResponse) = try await dataWithRetry(
                for: request,
                maxAttempts: maxAttempts
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NetworkDiagnostics.logError(url: request.url ?? baseURL, method: method, error: error)
            switch AppErrorClassification.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network:
                throw error
            case .domain:
                throw AppServiceError.message(Self.connectionErrorMessage(from: error))
            }
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер авторизации вернул неизвестный ответ.")
        }

        if let url = request.url {
            NetworkDiagnostics.logResponse(url: url, statusCode: httpResponse.statusCode, data: data)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Self.authError(statusCode: httpResponse.statusCode, data: data)
        }

        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            if Response.self == EmptyResponse.self {
                return EmptyResponse() as! Response
            }
            throw AppServiceError.message("Сервер авторизации вернул некорректный ответ.")
        }
    }

    private func dataWithRetry(
        for request: URLRequest,
        maxAttempts: Int
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 0 ..< max(maxAttempts, 1) {
            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if AppErrorClassification.isCancellation(error) {
                    throw CancellationError()
                }
                lastError = error
                guard attempt + 1 < maxAttempts, Self.shouldRetryConnectionError(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw lastError ?? AppServiceError.message("Не удалось подключиться к серверу авторизации.")
    }

    private static func authError(statusCode: Int, data: Data) -> Error {
        if let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            switch payload.error {
            case "CODE_RECENTLY_SENT":
                return AppServiceError.message(payload.message ?? "Код уже отправлен. Повторите через минуту.")
            case "INVALID_CODE":
                return AppServiceError.message("Код не подошел или истек.")
            case "USER_BLOCKED":
                return LumaWorkAuthError.accessRevoked
            default:
                break
            }
        }
        return AppServiceError.http(status: statusCode, fallback: "Ошибка авторизации")
    }

    private static func connectionErrorMessage(from error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Не удалось подключиться к серверу авторизации."
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return "Нет подключения к интернету для сервера авторизации."
        case .timedOut:
            return "Сервер авторизации не ответил вовремя."
        case .cannotFindHost, .dnsLookupFailed:
            return "Не удалось найти сервер авторизации."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Не удалось подключиться к серверу авторизации."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Не удалось установить защищённое соединение с сервером авторизации."
        default:
            return "Не удалось подключиться к серверу авторизации."
        }
    }

    private static func shouldRetryConnectionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

public enum LumaWorkAuthError: LocalizedError {
    case accessRevoked

    public var errorDescription: String? {
        switch self {
        case .accessRevoked:
            return "Доступ был отозван. Для восстановления обратитесь в поддержку."
        }
    }

    public static func isAccessRevoked(_ error: Error) -> Bool {
        guard case .accessRevoked = error as? LumaWorkAuthError else { return false }
        return true
    }
}

private struct CurrentUserResponse: Decodable { var user: AppUser }
private struct ErrorResponse: Decodable { var error: String?; var message: String? }
private struct EmptyResponse: Decodable {}
