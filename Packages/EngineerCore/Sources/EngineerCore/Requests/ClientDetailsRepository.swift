import Foundation
import Observation

@MainActor @Observable
public final class ClientDetailsRepository {
    private struct CompanyCache: Codable { let company: CompanyLookupCompany; let fetchedAt: Date }
    private struct Vault: Codable {
        var comments: [ClientPersonalComment]?
        var companies: [String: CompanyCache] = [:]
    }
    private let sessionProvider: () -> AppSession?
    private let contextProvider: () -> SessionContext?
    private let storageProvider: () throws -> ScopedSnapshotStorage
    private let serviceFactory: (AppSession) -> ClientDetailsService
    private let authFailure: () -> Void
    private var boundContext: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Vault, Error>?
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    private var revision: UInt64 = 0
    private var commentsFlight: Task<Void, Error>?
    private var companyFlights: [String: Task<Void, Error>] = [:]
    private var commentsUpdatedAt: Date?
    public private(set) var isSaving = false
    public private(set) var isLoading = false
    public private(set) var requiresRefresh = false
    public private(set) var error: String?
    public private(set) var cacheWarning: String?
    public private(set) var companyErrors: [String: String] = [:]
    public private(set) var loadingCompanies: Set<String> = []
    private var active: Bool { boundContext != nil && boundContext == contextProvider() }
    public var hasSnapshot: Bool { active && vault.comments != nil }
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage,
                service: @escaping (AppSession) -> ClientDetailsService, authFailure: @escaping () -> Void) {
        sessionProvider = session; contextProvider = context; storageProvider = storage; serviceFactory = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard boundContext != contextProvider() else { return }
        commentsFlight?.cancel(); companyFlights.values.forEach { $0.cancel() }; hydration?.cancel(); persistence?.cancel()
        commentsFlight = nil; companyFlights = [:]; hydration = nil; persistence = nil; persistenceID = nil
        vault = Vault(); hydrated = false; boundContext = contextProvider(); revision &+= 1
        commentsUpdatedAt = nil; isSaving = false; isLoading = false; requiresRefresh = false; error = nil; cacheWarning = nil
        companyErrors = [:]; loadingCompanies = []
    }
    private func capture() throws -> (SessionContext, ClientDetailsService) {
        synchronizeSession()
        guard active, let context = boundContext, let session = sessionProvider(), session.user.id == context.userID else { throw CancellationError() }
        return (context, serviceFactory(session))
    }
    private func check(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard active, boundContext == context else { throw CancellationError() }
    }
    private func handle(_ failure: Error) {
        if case AppServiceError.http(let status, _) = failure, status == 401 || status == 403 { authFailure() }
    }
    public func selected(tin: String, address: String, terminalID: String) -> ClientPersonalComment? {
        guard active, let comments = vault.comments else { return nil }
        let ordered = comments.sorted { $0.updatedAt > $1.updatedAt }
        let index = ClientPersonalCommentMatchingIndex(entries: ordered.map { .init(id: $0.id, tin: $0.normalizedTIN, addresses: $0.targets.map(\.address), terminalIDs: $0.terminalIDs) })
        let id = index.selectedID(tin: tin, address: address, terminalID: terminalID)
        return comments.first { $0.id == id }
    }
    public func company(_ tin: String) -> CompanyLookupCompany? { active ? vault.companies[tin]?.company : nil }
    private func hydrate(_ context: SessionContext) async throws {
        if hydrated { return }
        let task: Task<Vault, Error>
        if let hydration { task = hydration }
        else {
            let storage = try storageProvider(); let scope = try SnapshotScope(userID: context.userID)
            task = Task {
                let data = try await storage.load(key: "client-details.v1", scope: scope)
                try self.check(context)
                return try data.map { try JSONDecoder().decode(Vault.self, from: $0) } ?? Vault()
            }; hydration = task
        }
        do {
            let value = try await task.value; try check(context)
            if !hydrated { vault = value; hydrated = true; hydration = nil }
        } catch { try check(context); hydration = nil; hydrated = true; cacheWarning = error.localizedDescription }
    }
    private func persist(_ context: SessionContext) async throws {
        try check(context)
        let task: Task<Void, Error>
        if let persistence { task = persistence }
        else {
            let id = UUID(); persistenceID = id
            let storage = try storageProvider(); let scope = try SnapshotScope(userID: context.userID)
            task = Task {
                repeat {
                    try self.check(context); let written = self.revision
                    let data = try JSONEncoder().encode(self.vault)
                    try await storage.save(data, key: "client-details.v1", scope: scope); try self.check(context)
                    if written == self.revision { break }
                } while true
            }; persistence = task
        }
        let id = persistenceID
        do { try await task.value; try check(context); if persistenceID == id { persistence = nil; persistenceID = nil } }
        catch { if persistenceID == id { persistence = nil; persistenceID = nil }; throw error }
    }
    private func cache(_ context: SessionContext) async throws {
        do { try await persist(context); try check(context); cacheWarning = nil }
        catch { try check(context); cacheWarning = "Данные получены, но кеш не сохранён: " + error.localizedDescription }
    }
    public func load(force: Bool = false) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        if let flight = commentsFlight { try await flight.value; try check(context); return }
        guard !isSaving else { throw AppServiceError.message("Дождитесь сохранения комментария.") }
        if !force, !requiresRefresh, let date = commentsUpdatedAt, Date().timeIntervalSince(date) < 300 { return }
        isLoading = true; error = nil
        let task = Task {
            do {
                let rows = try await service.comments(); try self.check(context)
                self.vault.comments = rows; self.commentsUpdatedAt = Date(); self.requiresRefresh = false; self.revision &+= 1
                try await self.cache(context)
            } catch {
                if self.boundContext == context, !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription; self.handle(error) }
                throw error
            }
        }; commentsFlight = task
        defer { if boundContext == context { commentsFlight = nil; isLoading = false } }
        try await task.value; try check(context)
    }
    public func save(_ draft: ClientPersonalCommentDraft, expectedContext: SessionContext) async throws {
        let (context, service) = try capture()
        guard context == expectedContext else { throw CancellationError() }
        try await hydrate(context); try check(context)
        guard !isSaving, !requiresRefresh, draft.canSave else { throw AppServiceError.message("Обновите комментарии перед сохранением.") }
        isSaving = true
        defer { if boundContext == context { isSaving = false } }
        if let flight = commentsFlight { try await flight.value; try check(context) }
        // Once POST starts, cancellation or malformed response may hide a committed write.
        let saved: ClientPersonalComment
        do { saved = try await service.save(draft); try check(context) }
        catch {
            if boundContext == context {
                if case AppServiceError.http(let status, _) = error, let status, (400..<500).contains(status) {} else { requiresRefresh = true }
                self.error = requiresRefresh ? "Результат отправки неизвестен. Обновите комментарии перед повтором." : error.localizedDescription
                handle(error)
            }
            throw error
        }
        var rows = vault.comments ?? []
        rows.removeAll { $0.id == saved.id }
        if let source = draft.sourceCommentID, let index = rows.firstIndex(where: { $0.id == source }) {
            let transferred = Set(saved.terminalIDs.map(ClientPersonalCommentMatchingIndex.normalizedTerminalID))
            rows[index].terminalIDs.removeAll { transferred.contains(ClientPersonalCommentMatchingIndex.normalizedTerminalID($0)) }
        }
        rows.append(saved); vault.comments = rows; revision &+= 1; error = nil
        try await cache(context); try check(context)
    }
    public func loadCompany(_ tin: String, force: Bool = false) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        guard !tin.isEmpty, ClientPersonalCommentMatchingIndex.normalizedTIN(tin) == tin else { throw AppServiceError.message("Некорректный ИНН.") }
        if let flight = companyFlights[tin] { try await flight.value; try check(context); return }
        if !force, let cached = vault.companies[tin], Date().timeIntervalSince(cached.fetchedAt) < 300 { return }
        loadingCompanies.insert(tin); companyErrors[tin] = nil
        let task = Task {
            do {
                let company = try await service.company(tin); try self.check(context)
                self.vault.companies[tin] = CompanyCache(company: company, fetchedAt: Date()); self.revision &+= 1
                try await self.cache(context)
            } catch {
                if self.boundContext == context, !AppErrorClassification.isCancellation(error) { self.companyErrors[tin] = error.localizedDescription; self.handle(error) }
                throw error
            }
        }; companyFlights[tin] = task
        defer { if boundContext == context { companyFlights[tin] = nil; loadingCompanies.remove(tin) } }
        try await task.value; try check(context)
    }
}
