import Foundation

public struct AdminOverviewSnapshot: Equatable {
    public var system: AdminOverviewSystem
    public var resources: AdminOverviewVPSResources?
    public var stats: AdminOverviewStats
    public var storage: AdminOverviewStorage
    public var dataStorage: AdminOverviewDataStorage?
    public var recentActions: [AdminAuditAction]
}

public struct AdminOverviewSystem: Equatable {
    public var service: String
    public var status: String
    public var serverTime: Date?
    public var startedAt: Date?
    public var uptimeSeconds: Int64
    public var nodeVersion: String
    public var memoryResidentBytes: Int64

    public var isHealthy: Bool {
        ["ok", "healthy", "online", "up", "ready"].contains(status.lowercased())
    }
}

public struct AdminOverviewStats: Equatable {
    public var users: Int
    public var admins: Int
    public var blockedUsers: Int
    public var activeUsers7d: Int
    public var vehicles: Int
    public var vehicleCatalogs: Int
    public var missingVehicleImages: Int
    public var pendingVehicleImages: Int
    public var backpackBindings: Int
    public var missingBackpackImages: Int
    public var orphanImages: Int
}

public struct AdminOverviewStorage: Equatable {
    public var imageFiles: Int
    public var bytes: Int64
}

public struct AdminOverviewVPSResources: Equatable {
    public var capturedAt: Date?
    public var cpuUsagePercent: Double
    public var cpuCores: Int
    public var loadAverage1m: Double
    public var ramUsedBytes: Int64
    public var ramTotalBytes: Int64
    public var ramAvailableBytes: Int64
    public var ramUsagePercent: Double
    public var diskUsedBytes: Int64
    public var diskTotalBytes: Int64
    public var diskAvailableBytes: Int64
    public var diskUsagePercent: Double
}

public struct AdminOverviewDataStorage: Equatable {
    public var capturedAt: Date?
    public var totalBytes: Int64
    public var databaseBytes: Int64
    public var filesBytes: Int64
    public var uploadBytes: Int64
    public var reportBytes: Int64
    public var templateBytes: Int64
    public var databaseBackupBytes: Int64
    public var attributedUserBytes: Int64
    public var attributedFileBytes: Int64
    public var unattributedFileBytes: Int64
    public var usersVisible: Bool
    public var users: [AdminOverviewUserStorage]
}

public struct AdminOverviewUserStorage: Identifiable, Equatable {
    public var id: String { userID }

    public var userID: String
    public var email: String
    public var displayName: String
    public var databaseBytes: Int64
    public var fileBytes: Int64
    public var totalBytes: Int64
    public var recordCount: Int
    public var fileCount: Int
}

public struct AdminAuditAction: Identifiable, Equatable {
    public var id: String
    public var actorEmail: String
    public var action: String
    public var targetType: String
    public var targetID: String?
    public var summary: String?
    public var createdAt: Date?
}

@MainActor
public struct AdminOverviewAPI {
    private let baseURL: URL?
    private let http: HTTPClient

    public init(config: AppConfig, httpClient: HTTPClient? = nil) {
        http = httpClient ?? .confidential
        baseURL = try? AppConfig.validatedURL(config.lumaWorkAPIOrigin)
    }

    public func fetch(token: String) async throws -> AdminOverviewSnapshot {
        let response = try await http.request(
            try url(path: "/api/v2/admin/overview"),
            authToken: token, redactDiagnostics: true
        )
        guard let root = adminOverviewDictionary(response.json) else {
            throw AppServiceError.message("Сервер не вернул данные админки.")
        }
        let payload = adminOverviewDictionary(root["overview"])
            ?? adminOverviewDictionary(root["data"])
            ?? root

        let systemRaw = adminOverviewDictionary(payload["system"]) ?? [:]
        let resourcesRaw = adminOverviewDictionary(payload["resources"])
        let statsRaw = adminOverviewDictionary(payload["stats"]) ?? [:]
        let storageRaw = adminOverviewDictionary(payload["storage"]) ?? [:]
        let dataStorageRaw = adminOverviewDictionary(payload["dataStorage"] ?? payload["data_storage"])
        let actionsRaw = adminOverviewArray(payload["recentActions"] ?? payload["recent_actions"])

        let system = AdminOverviewSystem(
            service: adminOverviewString(systemRaw, keys: ["service", "name"]),
            status: adminOverviewString(systemRaw, keys: ["status", "state"], fallback: "unknown"),
            serverTime: adminOverviewDate(systemRaw["serverTime"] ?? systemRaw["server_time"]),
            startedAt: adminOverviewDate(systemRaw["startedAt"] ?? systemRaw["started_at"]),
            uptimeSeconds: adminOverviewInt64(systemRaw["uptimeSeconds"] ?? systemRaw["uptime_seconds"]),
            nodeVersion: adminOverviewString(systemRaw, keys: ["nodeVersion", "node_version"]),
            memoryResidentBytes: adminOverviewInt64(
                systemRaw["memoryResidentBytes"] ?? systemRaw["memory_resident_bytes"]
            )
        )
        let resources = resourcesRaw.map {
            AdminOverviewVPSResources(
                capturedAt: adminOverviewDate($0["capturedAt"] ?? $0["captured_at"]),
                cpuUsagePercent: adminOverviewDouble($0["cpuUsagePercent"] ?? $0["cpu_usage_percent"]),
                cpuCores: adminOverviewInt($0["cpuCores"] ?? $0["cpu_cores"]),
                loadAverage1m: adminOverviewDouble($0["loadAverage1m"] ?? $0["load_average_1m"]),
                ramUsedBytes: adminOverviewInt64($0["ramUsedBytes"] ?? $0["ram_used_bytes"]),
                ramTotalBytes: adminOverviewInt64($0["ramTotalBytes"] ?? $0["ram_total_bytes"]),
                ramAvailableBytes: adminOverviewInt64($0["ramAvailableBytes"] ?? $0["ram_available_bytes"]),
                ramUsagePercent: adminOverviewDouble($0["ramUsagePercent"] ?? $0["ram_usage_percent"]),
                diskUsedBytes: adminOverviewInt64($0["diskUsedBytes"] ?? $0["disk_used_bytes"]),
                diskTotalBytes: adminOverviewInt64($0["diskTotalBytes"] ?? $0["disk_total_bytes"]),
                diskAvailableBytes: adminOverviewInt64($0["diskAvailableBytes"] ?? $0["disk_available_bytes"]),
                diskUsagePercent: adminOverviewDouble($0["diskUsagePercent"] ?? $0["disk_usage_percent"])
            )
        }
        let stats = AdminOverviewStats(
            users: adminOverviewInt(statsRaw["users"]),
            admins: adminOverviewInt(statsRaw["admins"]),
            blockedUsers: adminOverviewInt(statsRaw["blockedUsers"] ?? statsRaw["blocked_users"]),
            activeUsers7d: adminOverviewInt(statsRaw["activeUsers7d"] ?? statsRaw["active_users_7d"]),
            vehicles: adminOverviewInt(statsRaw["vehicles"]),
            vehicleCatalogs: adminOverviewInt(statsRaw["vehicleCatalogs"] ?? statsRaw["vehicle_catalogs"]),
            missingVehicleImages: adminOverviewInt(
                statsRaw["missingVehicleImages"] ?? statsRaw["missing_vehicle_images"]
            ),
            pendingVehicleImages: adminOverviewInt(
                statsRaw["pendingVehicleImages"] ?? statsRaw["pending_vehicle_images"]
            ),
            backpackBindings: adminOverviewInt(statsRaw["backpackBindings"] ?? statsRaw["backpack_bindings"]),
            missingBackpackImages: adminOverviewInt(
                statsRaw["missingBackpackImages"] ?? statsRaw["missing_backpack_images"]
            ),
            orphanImages: adminOverviewInt(statsRaw["orphanImages"] ?? statsRaw["orphan_images"])
        )
        let storage = AdminOverviewStorage(
            imageFiles: adminOverviewInt(storageRaw["imageFiles"] ?? storageRaw["image_files"]),
            bytes: adminOverviewInt64(storageRaw["bytes"])
        )
        let dataStorage = dataStorageRaw.map { raw in
            let users = adminOverviewArray(raw["users"]).map { userRaw in
                AdminOverviewUserStorage(
                    userID: adminOverviewString(userRaw, keys: ["userId", "user_id", "id"]),
                    email: adminOverviewString(userRaw, keys: ["email"]),
                    displayName: adminOverviewString(userRaw, keys: ["displayName", "display_name", "email"]),
                    databaseBytes: adminOverviewInt64(userRaw["databaseBytes"] ?? userRaw["database_bytes"]),
                    fileBytes: adminOverviewInt64(userRaw["fileBytes"] ?? userRaw["file_bytes"]),
                    totalBytes: adminOverviewInt64(userRaw["totalBytes"] ?? userRaw["total_bytes"]),
                    recordCount: adminOverviewInt(userRaw["recordCount"] ?? userRaw["record_count"]),
                    fileCount: adminOverviewInt(userRaw["fileCount"] ?? userRaw["file_count"])
                )
            }
            .filter { !$0.userID.isEmpty }
            .sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                return $0.email.localizedStandardCompare($1.email) == .orderedAscending
            }

            return AdminOverviewDataStorage(
                capturedAt: adminOverviewDate(raw["capturedAt"] ?? raw["captured_at"]),
                totalBytes: adminOverviewInt64(raw["totalBytes"] ?? raw["total_bytes"]),
                databaseBytes: adminOverviewInt64(raw["databaseBytes"] ?? raw["database_bytes"]),
                filesBytes: adminOverviewInt64(raw["filesBytes"] ?? raw["files_bytes"]),
                uploadBytes: adminOverviewInt64(raw["uploadBytes"] ?? raw["upload_bytes"]),
                reportBytes: adminOverviewInt64(raw["reportBytes"] ?? raw["report_bytes"]),
                templateBytes: adminOverviewInt64(raw["templateBytes"] ?? raw["template_bytes"]),
                databaseBackupBytes: adminOverviewInt64(
                    raw["databaseBackupBytes"] ?? raw["database_backup_bytes"]
                ),
                attributedUserBytes: adminOverviewInt64(
                    raw["attributedUserBytes"] ?? raw["attributed_user_bytes"]
                ),
                attributedFileBytes: adminOverviewInt64(
                    raw["attributedFileBytes"] ?? raw["attributed_file_bytes"]
                ),
                unattributedFileBytes: adminOverviewInt64(
                    raw["unattributedFileBytes"] ?? raw["unattributed_file_bytes"]
                ),
                usersVisible: adminOverviewBool(raw["usersVisible"] ?? raw["users_visible"]),
                users: users
            )
        }
        let actions = actionsRaw.compactMap(AdminAuditAction.init(raw:)).sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }

        return AdminOverviewSnapshot(
            system: system,
            resources: resources,
            stats: stats,
            storage: storage,
            dataStorage: dataStorage,
            recentActions: actions
        )
    }

    public func audit(token: String) async throws -> [AdminAuditAction] {
        let response = try await http.request(try url(path: "/api/v2/admin/audit-log"), authToken: token, redactDiagnostics: true)
        guard let root = response.json as? [String: Any], let rows = root["actions"] as? [[String: Any]] else { throw GsmFuelError.invalidResponse }
        return rows.compactMap(AdminAuditAction.init(raw:))
    }
    private func url(path: String) throws -> URL {
        guard let baseURL else { throw AppServiceError.message("Не настроен адрес сервера.") }
        return baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

private extension AdminAuditAction {
    init?(raw: [String: Any]) {
        let action = adminOverviewString(raw, keys: ["action"])
        guard !action.isEmpty else { return nil }

        let createdAt = adminOverviewDate(raw["createdAt"] ?? raw["created_at"])
        let providedID = adminOverviewString(raw, keys: ["id"])
        id = providedID.isEmpty
            ? "\(action)-\(createdAt?.timeIntervalSince1970 ?? 0)-\(adminOverviewString(raw, keys: ["targetId", "target_id"]))"
            : providedID
        actorEmail = adminOverviewString(raw, keys: ["actorEmail", "actor_email"])
        self.action = action
        targetType = adminOverviewString(raw, keys: ["targetType", "target_type"])
        targetID = adminOverviewString(raw, keys: ["targetId", "target_id"]).nilIfAdminOverviewBlank
        summary = adminOverviewString(raw, keys: ["summary"]).nilIfAdminOverviewBlank
        self.createdAt = createdAt
    }
}

private func adminOverviewDictionary(_ raw: Any?) -> [String: Any]? {
    raw as? [String: Any]
}

private func adminOverviewArray(_ raw: Any?) -> [[String: Any]] {
    if let array = raw as? [[String: Any]] { return array }
    if let array = raw as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    return []
}

private func adminOverviewString(
    _ raw: [String: Any],
    keys: [String],
    fallback: String = ""
) -> String {
    for key in keys {
        if let value = raw[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = raw[key] as? NSNumber { return value.stringValue }
    }
    return fallback
}

private func adminOverviewInt(_ raw: Any?) -> Int {
    if let value = raw as? Int { return value }
    if let value = raw as? NSNumber { return value.intValue }
    if let value = raw as? String { return Int(value) ?? 0 }
    return 0
}

private func adminOverviewInt64(_ raw: Any?) -> Int64 {
    if let value = raw as? Int64 { return value }
    if let value = raw as? NSNumber { return value.int64Value }
    if let value = raw as? String { return Int64(value) ?? 0 }
    return 0
}

private func adminOverviewDouble(_ raw: Any?) -> Double {
    if let value = raw as? Double { return value }
    if let value = raw as? NSNumber { return value.doubleValue }
    if let value = raw as? String { return Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    return 0
}

private func adminOverviewBool(_ raw: Any?) -> Bool {
    if let value = raw as? Bool { return value }
    if let value = raw as? NSNumber { return value.boolValue }
    if let value = raw as? String {
        return ["true", "1", "yes"].contains(value.lowercased())
    }
    return false
}

private func adminOverviewDate(_ raw: Any?) -> Date? {
    if let date = raw as? Date { return date }
    if let number = raw as? NSNumber {
        let value = number.doubleValue
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    guard let value = raw as? String else { return nil }
    for formatter in AdminOverviewDateFormatters.iso {
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

private extension String {
    var nilIfAdminOverviewBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum AdminOverviewDateFormatters {
    static let iso: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()
}
