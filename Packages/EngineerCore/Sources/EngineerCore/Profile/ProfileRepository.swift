import Foundation
import Observation

public struct ProfilePreferences: Codable, Equatable, Sendable {
    public var card = VirtualCardData.default
    public var vehicleSectionVisible = true
    public init() {}
}
@MainActor @Observable
public final class ProfileRepository {
    private let config: AppConfig
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let applyUser: (AppUser, SessionContext) throws -> Void
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var hydrated = false
    private var persistence: Task<Void, Error>?
    private var revision = 0
    public private(set) var preferences = ProfilePreferences()
    public private(set) var isSaving = false
    public private(set) var requiresRefresh = false
    public private(set) var error: String?
    public init(config: AppConfig, session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, applyUser: @escaping (AppUser, SessionContext) throws -> Void, authFailure: @escaping () -> Void) {
        self.config = config; self.session = session; self.context = context; self.storage = storage; self.applyUser = applyUser; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }; persistence?.cancel(); persistence = nil
        bound = context(); preferences = .init(); hydrated = false; revision = 0; isSaving = false; requiresRefresh = false; error = nil
    }
    private func check(_ captured: SessionContext) throws { try Task.checkCancellation(); guard context() == captured, bound == captured else { throw CancellationError() } }
    private func capture() throws -> (SessionContext, DomainHTTPClient) {
        synchronizeSession(); guard let captured = bound, let session = session(), session.user.id == captured.userID else { throw CancellationError() }
        try check(captured); return (captured, DomainHTTPClient(config: config, token: session.token))
    }
    public func loadPreferences() async throws {
        let (captured, _) = try capture(); if hydrated { return }
        do {
            let data = try await storage().load(key: "profile-preferences.v1", scope: SnapshotScope(userID: captured.userID)); try check(captured)
            if !hydrated { preferences = try data.map { try JSONDecoder().decode(ProfilePreferences.self, from: $0) } ?? .init(); hydrated = true }
        } catch { try check(captured); hydrated = true; self.error = "Локальные настройки профиля недоступны." }
    }
    public func savePreferences(_ value: ProfilePreferences, expectedContext: SessionContext) async throws {
        let (captured, _) = try capture(); guard captured == expectedContext else { throw CancellationError() }
        try await loadPreferences(); try check(captured); preferences = value; revision += 1
        let task: Task<Void, Error>
        if let persistence { task = persistence }
        else {
            let vault = try storage(), scope = try SnapshotScope(userID: captured.userID)
            task = Task {
                repeat {
                    try self.check(captured); let version = self.revision, data = try JSONEncoder().encode(self.preferences)
                    try await vault.save(data, key: "profile-preferences.v1", scope: scope); try self.check(captured)
                    if self.revision == version { break }
                } while true
            }; persistence = task
        }
        do { try await task.value; try check(captured); persistence = nil; error = nil }
        catch { if bound == captured, context() == captured { persistence = nil; self.error = "Настройки не сохранены на Mac." }; throw error }
    }
    private func user(_ json: Any?, http: DomainHTTPClient) throws -> AppUser { try http.decode(AppUser.self, json: (json as? [String: Any])?["user"]) }
    public func refresh() async throws {
        let (captured, http) = try capture(); guard !isSaving else { throw GsmFuelError.busy }
        isSaving = true
        defer { if bound == captured { isSaving = false } }
        do {
            let updated = try user(await http.request("/me", timeout: 8), http: http); try check(captured)
            try applyUser(updated, captured); requiresRefresh = false; error = nil
        } catch {
            try check(captured)
            self.error = error.localizedDescription; if DomainHTTPClient.isUnauthorized(error) { authFailure() }
            throw error
        }
    }
    public func saveProfile(_ value: UserProfileData, base: UserProfileData?, expectedContext: SessionContext) async throws {
        try await mutate(expectedContext: expectedContext, verify: { $0.profile == base }) { http in
            try self.user(await http.request("/api/v2/profile", method: "PUT", body: value.requestBody), http: http)
        }
    }
    public func avatar(data: Data?, mimeType: String?, baseURL: String?, expectedContext: SessionContext) async throws {
        if let data { guard data.count >= 1024, data.count <= 8 * 1024 * 1024 else { throw AppServiceError.message("Выберите фото размером от 1 КБ до 8 МБ.") } }
        try await mutate(expectedContext: expectedContext, verify: { $0.avatarUrl == baseURL }) { http in
            let body: [String: Any]? = data.map { ["imageBase64": $0.base64EncodedString(), "mimeType": mimeType ?? "image/jpeg"] }
            return try self.user(await http.request("/api/v2/profile/avatar", method: data == nil ? "DELETE" : "POST", body: body, timeout: 45), http: http)
        }
    }
    private func mutate(expectedContext: SessionContext, verify: (AppUser) -> Bool, send: (DomainHTTPClient) async throws -> AppUser) async throws {
        let (captured, http) = try capture(); guard captured == expectedContext else { throw CancellationError() }
        guard !isSaving, !requiresRefresh else { throw AppServiceError.message("Обновите профиль перед повторной отправкой.") }
        isSaving = true; var submitted = false
        defer { if bound == captured { isSaving = false } }
        do {
            let current = try user(await http.request("/me", timeout: 8), http: http); try check(captured)
            guard current.id == captured.userID, verify(current) else { throw GsmFuelError.conflict }
            submitted = true; let updated = try await send(http); try check(captured)
            error = nil; try applyUser(updated, captured)
        } catch {
            try check(captured)
            if bound == captured {
                if submitted, DomainHTTPClient.isUncertain(error) { requiresRefresh = true; self.error = "Результат отправки неизвестен. Обновите профиль перед повтором." }
                else if !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription }
                if DomainHTTPClient.isUnauthorized(error) { authFailure() }
            }
            throw error
        }
    }
}
