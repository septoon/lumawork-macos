import Foundation

@MainActor
public struct AdminUsersAPI {
    private let baseURL: URL?
    private let http: HTTPClient

    public init(config: AppConfig, httpClient: HTTPClient? = nil) {
        http = httpClient ?? .confidential
        baseURL = try? AppConfig.validatedURL(config.lumaWorkAPIOrigin)
    }

    public func fetchUsers(token: String) async throws -> [AdminUserRecord] {
        let response = try await http.request(try url(path: "/api/v2/admin/users"), authToken: token, redactDiagnostics: true)
        guard response.json is [[String: Any]] || (["users", "data", "items"].contains { (response.json as? [String: Any])?[$0] is [Any] }) else { throw GsmFuelError.invalidResponse }
        return adminArray(from: response.json, keys: ["users", "data", "items"])
            .map(AdminUserRecord.init(raw:))
            .filter { !$0.id.isEmpty }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastActiveAt ?? lhs.registeredAt ?? .distantPast
                let rhsDate = rhs.lastActiveAt ?? rhs.registeredAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    public func fetchUser(id: String, token: String) async throws -> AdminUserRecord {
        let response = try await http.request(try url(path: "/api/v2/admin/users/\(try DomainHTTPClient.id(id))"), authToken: token, redactDiagnostics: true)
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    public func updateBlock(id: String, blockedUntil: Date?, token: String) async throws -> AdminUserRecord {
        var body: [String: Any] = ["isBlocked": blockedUntil != nil]
        body["blockedUntil"] = blockedUntil.map(AdminUsersDateFormatters.api.string(from:)) ?? NSNull()
        let response = try await http.request(
            try url(path: "/api/v2/admin/users/\(try DomainHTTPClient.id(id))/block"),
            method: "POST",
            body: body,
            authToken: token, redactDiagnostics: true
        )
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    public func updateAccess(
        id: String,
        isAdmin: Bool,
        permissions: Set<AdminPermission>,
        token: String
    ) async throws -> AdminUserRecord {
        let response = try await http.request(
            try url(path: "/api/v2/admin/users/\(try DomainHTTPClient.id(id))/access"),
            method: "PATCH",
            body: [
                "role": isAdmin ? "admin" : "user",
                "permissions": AdminPermission.allCases
                    .filter(permissions.contains)
                    .map(\.rawValue)
            ],
            authToken: token, redactDiagnostics: true
        )
        let raw = adminDictionary(from: response.json, keys: ["user", "data"])
            ?? (response.json as? [String: Any])
            ?? [:]
        return AdminUserRecord(raw: raw)
    }

    public func deleteUser(id: String, confirmationEmail: String, token: String) async throws {
        _ = try await http.request(
            try url(path: "/api/v2/admin/users/\(try DomainHTTPClient.id(id))"),
            method: "DELETE",
            body: ["confirmationEmail": confirmationEmail],
            authToken: token, redactDiagnostics: true
        )
    }

    public func sendUpdateEmail(
        userID: String?,
        version: String,
        build: String?,
        subject: String,
        body: String,
        token: String
    ) async throws -> AdminUpdateEmailResult {
        guard version.range(of: #"^\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil, version.count <= 40,
              build.map({ !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) ?? true,
              (1...180).contains(subject.trimmingCharacters(in: .whitespacesAndNewlines).count), (1...20000).contains(body.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw AppServiceError.message("Проверьте версию, сборку, тему и текст письма.") }
        let target: [String: Any] = userID.map { ["kind": "user", "userId": $0] } ?? ["kind": "outdated"]
        var payload: [String: Any] = [
            "target": target,
            "version": version,
            "subject": subject,
            "body": body
        ]
        payload["build"] = build.map { $0 as Any } ?? NSNull()
        let response = try await http.request(
            try url(path: "/api/v2/admin/users/update-email"),
            method: "POST",
            body: payload,
            authToken: token, redactDiagnostics: true
        )
        let raw = response.json as? [String: Any] ?? [:]
        return AdminUpdateEmailResult(
            sent: (raw["sent"] as? NSNumber)?.intValue ?? 0,
            failed: (raw["failed"] as? NSNumber)?.intValue ?? 0,
            matched: (raw["matched"] as? NSNumber)?.intValue ?? 0
        )
    }

    private func url(path: String) throws -> URL {
        guard let baseURL else { throw AppServiceError.message("Не настроен адрес сервера.") }
        return baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
