import Foundation
import Observation

@MainActor @Observable
public final class SalaryRepository {
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: (AppSession) -> SalaryService
    private let authFailure: () -> Void
    private let access: SalaryAccess
    private var bound: SessionContext?
    private var values: [SalaryEntry] = []
    private var hydrated = false
    private var loaded = false
    private var hydration: Task<[SalaryEntry], Error>?
    private var flight: Task<Void, Error>?
    private var flightID: UUID?
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    private var revision: UInt64 = 0
    public private(set) var connection: GsmFuelConnection = .cached
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var requiresRefresh = false
    public private(set) var error: String?
    public private(set) var cacheWarning: String?
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> SalaryService, access: SalaryAccess, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.access = access; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        flight?.cancel(); hydration?.cancel(); persistence?.cancel(); flight = nil; flightID = nil; hydration = nil; persistence = nil; persistenceID = nil
        access.lockAll(); bound = context(); values = []; hydrated = false; loaded = false; revision &+= 1
        connection = .cached; isLoading = false; isSaving = false; requiresRefresh = false; error = nil; cacheWarning = nil
    }
    public func entries(grant: SalaryAccessGrant?) -> [SalaryEntry] { bound == context() && access.accepts(grant) ? values : [] }
    private func check(_ captured: SessionContext, _ grant: SalaryAccessGrant) throws {
        try Task.checkCancellation()
        guard bound == captured, context() == captured, access.accepts(grant) else { throw CancellationError() }
    }
    private func capture(_ grant: SalaryAccessGrant) throws -> (SessionContext, SalaryService) {
        synchronizeSession()
        guard let captured = bound, let session = session(), session.user.id == captured.userID else { throw CancellationError() }
        try check(captured, grant); return (captured, service(session))
    }
    private func hydrate(_ captured: SessionContext, _ grant: SalaryAccessGrant) async throws {
        if hydrated { return }
        let task: Task<[SalaryEntry], Error>
        if let hydration { task = hydration }
        else {
            let storage = try storage(); let scope = try SnapshotScope(userID: captured.userID)
            task = Task { let data = try await storage.load(key: "salary.v1", scope: scope); return try data.map { try JSONDecoder().decode([SalaryEntry].self, from: $0) } ?? [] }; hydration = task
        }
        do { let result = try await task.value; try check(captured, grant); if !hydrated { values = result; hydrated = true; hydration = nil } }
        catch { try check(captured, grant); hydration = nil; hydrated = true; cacheWarning = "Локальный кеш зарплаты недоступен." }
    }
    private func cache(_ captured: SessionContext, _ grant: SalaryAccessGrant) async throws {
        try check(captured, grant)
        do {
            let task: Task<Void, Error>
            if let persistence { task = persistence }
            else {
                let storage = try storage(); let scope = try SnapshotScope(userID: captured.userID)
                let id = UUID(); persistenceID = id
                task = Task {
                    repeat {
                        try self.check(captured, grant); let version = self.revision; let data = try JSONEncoder().encode(self.values)
                        try await storage.save(data, key: "salary.v1", scope: scope); try self.check(captured, grant)
                        if version == self.revision { break }
                    } while true
                }; persistence = task
            }
            let id = persistenceID
            do { try await task.value; try check(captured, grant); if persistenceID == id { persistence = nil; persistenceID = nil }; cacheWarning = nil }
            catch { if persistenceID == id { persistence = nil; persistenceID = nil }; throw error }
        } catch { try check(captured, grant); cacheWarning = "Данные получены, но кеш зарплаты не сохранён." }
    }
    public func load(grant: SalaryAccessGrant, force: Bool = false) async throws {
        let (captured, service) = try capture(grant); try await hydrate(captured, grant); try check(captured, grant)
        if let existing = flight {
            let existingID = flightID
            do { try await existing.value; try check(captured, grant); return }
            catch {
                try check(captured, grant)
                guard AppErrorClassification.isCancellation(error) else { throw error }
                // Another window can revoke the grant that started this shared read.
                if flightID == existingID { flight = nil; flightID = nil; isLoading = false }
                try await load(grant: grant, force: force); return
            }
        }
        guard !isSaving else { throw GsmFuelError.busy }
        if loaded, !force, !requiresRefresh { return }
        let id = UUID(); flightID = id; isLoading = true; error = nil
        let task = Task {
            do { let result = try await service.entries(); try self.check(captured, grant); self.values = result; self.connection = .online; self.loaded = true; self.requiresRefresh = false; self.revision &+= 1; try await self.cache(captured, grant) }
            catch { if self.bound == captured, self.access.accepts(grant), !AppErrorClassification.isCancellation(error) { self.error = "Не удалось обновить зарплату. Попробуйте позже."; if case .network = AppErrorClassification.classification(for: error) { self.connection = .offline }; if DomainHTTPClient.isUnauthorized(error) { self.authFailure() } }; throw error }
        }; flight = task
        defer { if flightID == id { flightID = nil; flight = nil; isLoading = false } }
        try await task.value; try check(captured, grant)
    }
    public func save(_ entry: SalaryEntry, base: SalaryEntry?, grant: SalaryAccessGrant) async throws -> SalaryEntry {
        let (captured, service) = try capture(grant); _ = try SalaryService.payload(entry)
        guard entry.id == base?.id else { throw GsmFuelError.conflict }
        guard let saved = try await mutate(base: base, grant: grant, captured: captured, service: service, send: { try await service.save(entry) }) else { throw GsmFuelError.invalidResponse }; return saved
    }
    public func delete(_ base: SalaryEntry, grant: SalaryAccessGrant) async throws {
        let (captured, service) = try capture(grant); guard let id = base.id else { throw GsmFuelError.invalidResponse }
        _ = try await mutate(base: base, grant: grant, captured: captured, service: service) { try await service.delete(id: id); return nil }
    }
    private func mutate(base: SalaryEntry?, grant: SalaryAccessGrant, captured: SessionContext, service: SalaryService, send: () async throws -> SalaryEntry?) async throws -> SalaryEntry? {
        try await hydrate(captured, grant); try check(captured, grant)
        guard !isSaving, !requiresRefresh else { throw AppServiceError.message("Обновите зарплату перед повторной отправкой.") }
        isSaving = true; var submitted = false
        defer { if bound == captured { isSaving = false } }
        do {
            if let flight { try await flight.value; try check(captured, grant) }
            if let base { let current = try await service.entries(); try check(captured, grant); guard current.first(where: { $0.stableID == base.stableID }) == base else { throw GsmFuelError.conflict } }
            submitted = true
            let result = try await send(); try check(captured, grant)
            if let base { values.removeAll { $0.stableID == base.stableID } }
            if let result { values.removeAll { $0.stableID == result.stableID }; values.append(result) }
            loaded = false; revision &+= 1; error = nil; try await cache(captured, grant); return result
        } catch {
            if bound == captured {
                if submitted, DomainHTTPClient.isUncertain(error) { requiresRefresh = true; self.error = "Результат отправки неизвестен. Обновите зарплату перед повтором." }
                if DomainHTTPClient.isUnauthorized(error) { authFailure() }
            }
            throw error
        }
    }
}
