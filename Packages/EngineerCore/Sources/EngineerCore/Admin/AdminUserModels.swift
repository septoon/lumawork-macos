import Foundation

public struct AdminUserRecord: Codable, Identifiable, Hashable {
    public var id: String
    public var email: String
    public var role: String
    public var adminPermissions: [String]
    public var isProtectedAdmin: Bool
    public var profile: UserProfileData?
    public var avatarUrl: String?
    public var registeredAt: Date?
    public var lastActiveAt: Date?
    public var appVersion: String?
    public var appBuild: String?
    public var appVersionSeenAt: Date?
    public var isBlocked: Bool
    public var blockedUntil: Date?

    public var displayName: String {
        profile?.fullName ?? email
    }

    public var jobTitle: String {
        UserProfileData.clean(profile?.jobTitle) ?? (isAdmin ? "Администратор" : "Пользователь")
    }

    public var isAdmin: Bool {
        ["admin", "administrator", "superadmin", "owner"].contains(role.lowercased())
    }

    public var permissionSet: Set<AdminPermission> {
        Set(adminPermissions.compactMap(AdminPermission.init(rawValue:)))
    }

    public var effectiveIsBlocked: Bool {
        guard isBlocked else { return false }
        if let blockedUntil {
            return blockedUntil > Date()
        }
        return true
    }

    public var appVersionDisplay: String {
        let version = UserProfileData.clean(appVersion)
        let build = UserProfileData.clean(appBuild)
        if let version, let build { return "\(version) (\(build))" }
        if let version { return version }
        if let build { return "Сборка \(build)" }
        return "Не определена"
    }
}

public struct AdminUpdateEmailResult: Hashable {
    public let sent: Int
    public let failed: Int
    public let matched: Int
}

extension AdminUserRecord {
    public var isRecentlyActive: Bool {
        guard let lastActiveAt else { return false }
        return lastActiveAt >= Date().addingTimeInterval(-7 * 24 * 60 * 60)
    }

    public init(raw: [String: Any]) {
        let id = adminString(raw, keys: ["id", "userId", "user_id", "_id"])
        let email = adminString(raw, keys: ["email", "mail", "login"])
        self.id = adminFirstNonEmpty(id, email)
        self.email = adminFirstNonEmpty(email, id)
        role = adminFirstNonEmpty(adminString(raw, keys: ["role"]), fallback: "user")
        adminPermissions = adminStringArray(raw["adminPermissions"] ?? raw["admin_permissions"])
        isProtectedAdmin = adminBool(raw, keys: ["isProtectedAdmin", "is_protected_admin"])
        let profileRaw = adminDictionary(from: raw, keys: ["profile", "userProfile", "user_profile"])
        profile = profileRaw.flatMap(adminUserProfile)
        avatarUrl = adminString(raw, keys: ["avatarUrl", "avatar_url", "avatar"])
        registeredAt = adminDate(raw, keys: ["registeredAt", "registered_at", "createdAt", "created_at"])
        lastActiveAt = adminDate(raw, keys: ["lastActiveAt", "last_active_at", "lastSeenAt", "last_seen_at"])
        appVersion = adminString(raw, keys: ["appVersion", "app_version", "lastAppVersion"])
        appBuild = adminString(raw, keys: ["appBuild", "app_build", "lastAppBuild"])
        appVersionSeenAt = adminDate(raw, keys: ["appVersionSeenAt", "app_version_seen_at", "lastAppSeenAt"])
        isBlocked = adminBool(raw, keys: ["isBlocked", "is_blocked", "blocked", "disabled"])
        blockedUntil = adminDate(raw, keys: ["blockedUntil", "blocked_until", "blockedTo", "blocked_to"])
    }
}

private func adminUserProfile(from raw: [String: Any]) -> UserProfileData {
    UserProfileData(
        firstName: adminString(raw, keys: ["firstName", "first_name"]),
        lastName: adminString(raw, keys: ["lastName", "last_name"]),
        middleName: adminString(raw, keys: ["middleName", "middle_name"]),
        jobTitle: adminString(raw, keys: ["jobTitle", "job_title", "title"]),
        departmentTitle: adminString(raw, keys: ["departmentTitle", "department_title"]),
        departmentGroup: adminString(raw, keys: ["departmentGroup", "department_group"]),
        personnelNumber: adminString(raw, keys: ["personnelNumber", "personnel_number"]),
        city: adminString(raw, keys: ["city", "workCity", "work_city"]),
        personalPhone: adminString(raw, keys: ["personalPhone", "personal_phone", "phone"]),
        workEmail: adminString(raw, keys: ["workEmail", "work_email"]),
        vehicleModel: adminString(raw, keys: ["vehicleModel", "vehicle_model"]),
        vehiclePlate: adminString(raw, keys: ["vehiclePlate", "vehicle_plate", "licensePlate", "license_plate"]),
        vehicleVin: adminString(raw, keys: ["vehicleVin", "vehicle_vin", "vin"]),
        vehicleSts: adminString(raw, keys: ["vehicleSts", "vehicle_sts", "sts"]),
        vehiclePts: adminString(raw, keys: ["vehiclePts", "vehicle_pts", "pts"]),
        vehicleColor: adminString(raw, keys: ["vehicleColor", "vehicle_color", "color"]),
        engineVolumeCm3: adminString(raw, keys: ["engineVolumeCm3", "engine_volume_cm3"]),
        enginePowerHp: adminString(raw, keys: ["enginePowerHp", "engine_power_hp"]),
        initialMileageKm: adminString(raw, keys: ["initialMileageKm", "initial_mileage_km"]),
        routeWarehouseAddress: adminString(raw, keys: ["routeWarehouseAddress", "route_warehouse_address"]),
        routeHomeAddress: adminString(raw, keys: ["routeHomeAddress", "route_home_address"])
    )
}

func adminDictionary(from raw: Any?, keys: [String]) -> [String: Any]? {
    if let dictionary = raw as? [String: Any] {
        for key in keys {
            if let nested = dictionary[key] as? [String: Any] { return nested }
        }
        return dictionary
    }
    return nil
}

func adminArray(from raw: Any?, keys: [String]) -> [[String: Any]] {
    if let array = raw as? [[String: Any]] { return array }
    guard let dictionary = raw as? [String: Any] else { return [] }
    for key in keys {
        if let array = dictionary[key] as? [[String: Any]] { return array }
        if let array = dictionary[key] as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    }
    return []
}

private func adminString(_ raw: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = raw[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = raw[key] as? NSNumber { return value.stringValue }
    }
    return ""
}

private func adminStringArray(_ raw: Any?) -> [String] {
    if let values = raw as? [String] { return values }
    if let values = raw as? [Any] { return values.compactMap { $0 as? String } }
    return []
}

private func adminBool(_ raw: [String: Any], keys: [String]) -> Bool {
    for key in keys {
        if let value = raw[key] as? Bool { return value }
        if let value = raw[key] as? NSNumber { return value.boolValue }
        if let value = raw[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "blocked": return true
            case "false", "0", "no", "active": return false
            default: break
            }
        }
    }
    return false
}

private func adminDate(_ raw: [String: Any], keys: [String]) -> Date? {
    for key in keys {
        guard let value = raw[key] else { continue }
        if let date = adminDate(from: value) { return date }
    }
    return nil
}

private func adminDate(from raw: Any) -> Date? {
    if let date = raw as? Date { return date }
    if let number = raw as? NSNumber {
        let value = number.doubleValue
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    guard let string = raw as? String else { return nil }
    for formatter in AdminUsersDateFormatters.iso {
        if let date = formatter.date(from: string) { return date }
    }
    for formatter in AdminUsersDateFormatters.input {
        if let date = formatter.date(from: string) { return date }
    }
    if let value = Double(string) {
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
    return nil
}

private func adminFirstNonEmpty(_ values: String..., fallback: String = "") -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? fallback
}

enum AdminUsersDateFormatters {
    static let api: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    static let input: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "dd.MM.yyyy HH:mm:ss"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

}
