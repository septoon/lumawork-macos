import Foundation
import Observation

@MainActor @Observable
public final class AdminRepository {
    private let access: ProtectedAccess
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let usersAPI: AdminUsersAPI
    private let overviewAPI: AdminOverviewAPI
    private let feedbackAPI: (AppSession) -> FeedbackAPI
    private let authFailure: () -> Void
    private let report: (String) -> Void
    private var bound: SessionContext?
    private var protectionGeneration: UInt64
    private var permissions: Set<AdminPermission> = []
    private var role: String?
    private var loaded: Set<AdminPermission> = []
    public private(set) var accessGeneration = UUID()
    private var users: [AdminUserRecord] = []
    private var overview: AdminOverviewSnapshot?
    private var audit: [AdminAuditAction] = []
    private var feedback: [FeedbackMessage] = []
    public private(set) var loading: Set<AdminPermission> = []
    public private(set) var isSaving = false
    public private(set) var forbidden = false
    public private(set) var requiresRefresh = false
    public private(set) var errors: [AdminPermission: String] = [:]
    public init(access: ProtectedAccess, session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, usersAPI: AdminUsersAPI, overviewAPI: AdminOverviewAPI, feedbackAPI: @escaping (AppSession) -> FeedbackAPI, authFailure: @escaping () -> Void, report: @escaping (String) -> Void) {
        protectionGeneration = access.currentGeneration
        self.access = access; self.session = session; self.context = context; self.usersAPI = usersAPI; self.overviewAPI = overviewAPI; self.feedbackAPI = feedbackAPI; self.authFailure = authFailure; self.report = report
        bound = context(); permissions = session()?.user.adminPermissionSet ?? []; role = session()?.user.role
    }
    public func synchronizeSession() {
        let user = session()?.user
        guard protectionGeneration != access.currentGeneration || bound != context() || permissions != (user?.adminPermissionSet ?? []) || role != user?.role else { return }
        protectionGeneration = access.currentGeneration; access.lockAll(); bound = context(); permissions = user?.adminPermissionSet ?? []; role = user?.role
        clear(); forbidden = false; requiresRefresh = false; errors = [:]
    }
    public func lock() { access.lockAll(); clear() }
    private func clear() {
        accessGeneration = UUID(); users = []; overview = nil; audit = []; feedback = []; loaded = []; loading = []; isSaving = false
    }
    private func capture(_ permission: AdminPermission, grant: ProtectedAccessGrant?, expectedContext: SessionContext? = nil) throws -> (SessionContext, AppSession, UUID) {
        synchronizeSession()
        guard access.accepts(grant) else { throw CancellationError() }
        guard let captured = bound, let session = session(), session.user.id == captured.userID,
              expectedContext == nil || expectedContext == captured else { throw CancellationError() }
        guard session.user.can(permission) else { throw AppServiceError.http(status: 403, fallback: "Нет разрешения на это действие.") }
        return (captured, session, accessGeneration)
    }
    private func check(_ captured: SessionContext, generation: UUID, grant: ProtectedAccessGrant?) throws {
        try Task.checkCancellation()
        guard access.accepts(grant), context() == captured, bound == captured, accessGeneration == generation,
              session()?.user.adminPermissionSet == permissions, session()?.user.role == role else { throw CancellationError() }
    }
    private func failure(_ error: Error, permission: AdminPermission, captured: SessionContext, generation: UUID, grant: ProtectedAccessGrant?) {
        guard access.accepts(grant), context() == captured, bound == captured, accessGeneration == generation, !AppErrorClassification.isCancellation(error) else { return }
        if case AppServiceError.http(let status, _) = error, status == 403 || status == 401 {
            access.lockAll(); clear(); forbidden = true; errors = [permission: "Доступ запрещён сервером. Обновите права доступа."]
            if status == 401 { authFailure() }
        } else { errors[permission] = error.localizedDescription }
        report(errors[permission] ?? error.localizedDescription)
    }
    public func load(_ permission: AdminPermission, grant: ProtectedAccessGrant?, force: Bool = false) async throws {
        let (captured, session, generation) = try capture(permission, grant: grant)
        guard !loading.contains(permission), force || !loaded.contains(permission) else { return }
        loading.insert(permission)
        defer { if generation == accessGeneration { loading.remove(permission) } }
        do {
            switch permission {
            case .viewUsers:
                let value = try await usersAPI.fetchUsers(token: session.token); try check(captured, generation: generation, grant: grant); users = value
            case .viewOverview:
                var value = try await overviewAPI.fetch(token: session.token); try check(captured, generation: generation, grant: grant)
                if !session.user.can(.viewAuditLog) { value.recentActions = [] }
                overview = value
            case .viewAuditLog:
                let value = try await overviewAPI.audit(token: session.token); try check(captured, generation: generation, grant: grant); audit = value
            case .viewFeedback:
                let value = try await feedbackAPI(session).messages(admin: true); try check(captured, generation: generation, grant: grant); feedback = value
            default: throw AppServiceError.message("Этот раздел ещё не перенесён.")
            }
            loaded.insert(permission); errors[permission] = nil; forbidden = false
            if force { requiresRefresh = false }
        } catch { failure(error, permission: permission, captured: captured, generation: generation, grant: grant); throw error }
    }
    public func refreshUser(id: String, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        let (captured, session, generation) = try capture(.viewUsers, grant: grant, expectedContext: expectedContext)
        do {
            let value = try await usersAPI.fetchUser(id: id, token: session.token); try check(captured, generation: generation, grant: grant)
            guard value.id == id else { throw GsmFuelError.invalidResponse }; replace(value)
        } catch { failure(error, permission: .viewUsers, captured: captured, generation: generation, grant: grant); throw error }
    }
    private func mutate(_ permission: AdminPermission, grant: ProtectedAccessGrant?, expectedContext: SessionContext, operation: (SessionContext, AppSession, UUID) async throws -> Void) async throws {
        let (captured, session, generation) = try capture(permission, grant: grant, expectedContext: expectedContext)
        guard !isSaving, !requiresRefresh else { throw AppServiceError.message("Обновите данные перед следующей операцией.") }
        isSaving = true
        defer { if accessGeneration == generation { isSaving = false } }
        do {
            try await operation(captured, session, generation); try check(captured, generation: generation, grant: grant)
            errors[permission] = nil; report("Изменения сохранены.")
        } catch {
            if context() == captured, accessGeneration == generation, DomainHTTPClient.isUncertain(error) { requiresRefresh = true }
            failure(error, permission: permission, captured: captured, generation: generation, grant: grant); throw error
        }
    }
    private func target(_ user: AdminUserRecord, session: AppSession, captured: SessionContext, generation: UUID, grant: ProtectedAccessGrant?) async throws -> AdminUserRecord {
        guard session.user.can(.viewUsers) else { throw AppServiceError.http(status: 403, fallback: "Нет доступа к пользователям.") }
        let fresh = try await usersAPI.fetchUser(id: user.id, token: session.token); try check(captured, generation: generation, grant: grant)
        guard fresh.id == user.id, fresh.id != captured.userID, !fresh.isProtectedAdmin else { throw AppServiceError.message("Текущего или защищённого администратора изменять нельзя.") }
        return fresh
    }
    public func block(_ user: AdminUserRecord, until: Date?, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        if let until, until <= Date() { throw AppServiceError.message("Укажите будущую дату окончания блокировки.") }
        try await mutate(.blockUsers, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            _ = try await target(user, session: session, captured: captured, generation: generation, grant: grant)
            let value = try await usersAPI.updateBlock(id: user.id, blockedUntil: until, token: session.token); try check(captured, generation: generation, grant: grant)
            guard value.id == user.id else { throw GsmFuelError.invalidResponse }; replace(value)
        }
    }
    public func access(_ user: AdminUserRecord, isAdmin: Bool, permissions: Set<AdminPermission>, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        try await mutate(.manageUserPermissions, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            _ = try await target(user, session: session, captured: captured, generation: generation, grant: grant)
            let value = try await usersAPI.updateAccess(id: user.id, isAdmin: isAdmin, permissions: permissions, token: session.token); try check(captured, generation: generation, grant: grant)
            guard value.id == user.id else { throw GsmFuelError.invalidResponse }; replace(value)
        }
    }
    public func delete(_ user: AdminUserRecord, confirmationEmail: String, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        try await mutate(.deleteUsers, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            let fresh = try await target(user, session: session, captured: captured, generation: generation, grant: grant)
            guard confirmationEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fresh.email.lowercased() else { throw AppServiceError.message("Email подтверждения не совпадает.") }
            try await usersAPI.deleteUser(id: user.id, confirmationEmail: confirmationEmail, token: session.token); try check(captured, generation: generation, grant: grant)
            users.removeAll { $0.id == user.id }
        }
    }
    public func notify(userID: String?, version: String, build: String?, subject: String, body: String, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws -> AdminUpdateEmailResult? {
        var result: AdminUpdateEmailResult?
        try await mutate(.notifyUsers, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            let value = try await usersAPI.sendUpdateEmail(userID: userID, version: version, build: build, subject: subject, body: body, token: session.token)
            try check(captured, generation: generation, grant: grant); result = value
        }
        return result
    }
    public func updateFeedback(id: String, status: FeedbackStatus, priority: FeedbackPriority, note: String, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        try await mutate(.manageFeedback, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            guard session.user.can(.viewFeedback) else { throw AppServiceError.http(status: 403, fallback: "Нет доступа к обратной связи.") }
            let value = try await feedbackAPI(session).update(id: id, status: status, priority: priority, note: note); try check(captured, generation: generation, grant: grant)
            guard value.id == id else { throw GsmFuelError.invalidResponse }
            feedback.removeAll { $0.id == id }; feedback.insert(value, at: 0)
        }
    }
    public func retryFeedbackEmail(id: String, grant: ProtectedAccessGrant?, expectedContext: SessionContext) async throws {
        try await mutate(.manageFeedback, grant: grant, expectedContext: expectedContext) { captured, session, generation in
            try await feedbackAPI(session).retryEmail(id: id); try check(captured, generation: generation, grant: grant)
        }
        try await load(.viewFeedback, grant: grant, force: true)
    }
    public func attachment(reportID: String, attachmentID: String, grant: ProtectedAccessGrant?) async throws -> URL {
        let (captured, session, generation) = try capture(.viewFeedback, grant: grant)
        do {
            let file = try await feedbackAPI(session).attachment(reportID: reportID, attachmentID: attachmentID, admin: true)
            do { try check(captured, generation: generation, grant: grant); return file } catch { try? FileManager.default.removeItem(at: file); throw error }
        } catch { failure(error, permission: .viewFeedback, captured: captured, generation: generation, grant: grant); throw error }
    }
    public func users(grant: ProtectedAccessGrant?) -> [AdminUserRecord] { canRead(.viewUsers, grant: grant) ? users : [] }
    public func overview(grant: ProtectedAccessGrant?) -> AdminOverviewSnapshot? { canRead(.viewOverview, grant: grant) ? overview : nil }
    public func audit(grant: ProtectedAccessGrant?) -> [AdminAuditAction] { canRead(.viewAuditLog, grant: grant) ? audit : [] }
    public func feedback(grant: ProtectedAccessGrant?) -> [FeedbackMessage] { canRead(.viewFeedback, grant: grant) ? feedback : [] }
    private func canRead(_ permission: AdminPermission, grant: ProtectedAccessGrant?) -> Bool {
        access.accepts(grant) && bound == context() && session()?.user.can(permission) == true && session()?.user.adminPermissionSet == permissions && session()?.user.role == role && !forbidden
    }
    private func replace(_ user: AdminUserRecord) { users.removeAll { $0.id == user.id }; users.append(user) }
}
