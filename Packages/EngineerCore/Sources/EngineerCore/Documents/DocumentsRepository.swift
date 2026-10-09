import Foundation
import Observation

@MainActor @Observable
public final class DocumentsRepository {
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: (AppSession) -> DocumentService
    private let access: SalaryAccess
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var values: [DocumentCollection: [ServerDocument]] = [:]
    private var hydrated: Set<DocumentCollection> = []
    private var loaded: Set<DocumentCollection> = []
    private var flights: [DocumentCollection: Task<Void, Error>] = [:]
    private var flightIDs: [DocumentCollection: UUID] = [:]
    private var persistence: [DocumentCollection: Task<Void, Error>] = [:]
    private var revisions: [DocumentCollection: Int] = [:]
    public private(set) var busy: Set<DocumentCollection> = []
    public private(set) var requiresRefresh: Set<DocumentCollection> = []
    private var errors: [DocumentCollection: String] = [:]
    private var warnings: [DocumentCollection: String] = [:]
    private var connections: [DocumentCollection: GsmFuelConnection] = [:]
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> DocumentService, access: SalaryAccess, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.access = access; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        flights.values.forEach { $0.cancel() }; persistence.values.forEach { $0.cancel() }
        bound = context(); values = [:]; hydrated = []; loaded = []; flights = [:]; flightIDs = [:]; persistence = [:]; revisions = [:]; busy = []; requiresRefresh = []; errors = [:]; warnings = [:]; connections = [:]
    }
    public func permits(_ collection: DocumentCollection, grant: SalaryAccessGrant? = nil) -> Bool { bound == context() && bound != nil && (!collection.isProtected || access.accepts(grant)) }
    public func documents(_ collection: DocumentCollection, grant: SalaryAccessGrant? = nil) -> [ServerDocument] { permits(collection, grant: grant) ? values[collection] ?? [] : [] }
    public func error(_ collection: DocumentCollection, grant: SalaryAccessGrant? = nil) -> String? { permits(collection, grant: grant) ? errors[collection] ?? warnings[collection] : nil }
    public func connection(_ collection: DocumentCollection, grant: SalaryAccessGrant? = nil) -> GsmFuelConnection { permits(collection, grant: grant) ? connections[collection] ?? .cached : .cached }
    public func isLoading(_ collection: DocumentCollection) -> Bool { flights[collection] != nil }
    private func check(_ captured: SessionContext, _ collection: DocumentCollection, _ grant: SalaryAccessGrant?) throws {
        try Task.checkCancellation(); guard captured == bound, context() == captured, permits(collection, grant: grant) else { throw CancellationError() }
    }
    private func capture(_ collection: DocumentCollection, _ grant: SalaryAccessGrant?) throws -> (SessionContext, DocumentService) {
        synchronizeSession(); guard let captured = bound, let session = session(), captured.userID == session.user.id else { throw CancellationError() }
        try check(captured, collection, grant); return (captured, service(session))
    }
    private func hydrate(_ captured: SessionContext, _ collection: DocumentCollection, _ grant: SalaryAccessGrant?) async throws {
        guard !hydrated.contains(collection) else { return }
        do {
            let data = try await storage().load(key: "documents." + collection.cacheKey + ".v1", scope: SnapshotScope(userID: captured.userID))
            try check(captured, collection, grant)
            if !hydrated.contains(collection) { values[collection] = try data.map { try JSONDecoder().decode([ServerDocument].self, from: $0) } ?? []; hydrated.insert(collection) }
        } catch { try check(captured, collection, grant); hydrated.insert(collection); warnings[collection] = "Локальный кеш документов недоступен." }
    }
    private func cache(_ captured: SessionContext, _ collection: DocumentCollection, _ grant: SalaryAccessGrant?) async throws {
        try check(captured, collection, grant)
        do {
            let task: Task<Void, Error>
            if let pending = persistence[collection] { task = pending }
            else {
                let vault = try storage(), scope = try SnapshotScope(userID: captured.userID)
                task = Task {
                    repeat {
                        try self.check(captured, collection, grant)
                        let revision = self.revisions[collection], data = try JSONEncoder().encode(self.values[collection] ?? [])
                        try await vault.save(data, key: "documents." + collection.cacheKey + ".v1", scope: scope)
                        try self.check(captured, collection, grant)
                        if revision == self.revisions[collection] { break }
                    } while true
                }; persistence[collection] = task
            }
            do { try await task.value; try check(captured, collection, grant); persistence[collection] = nil; warnings[collection] = nil }
            catch { if bound == captured { persistence[collection] = nil }; throw error }
        } catch { try check(captured, collection, grant); warnings[collection] = "Документы получены, но кеш не сохранён." }
    }
    public func load(_ collection: DocumentCollection, grant: SalaryAccessGrant? = nil, force: Bool = false) async throws {
        let (captured, api) = try capture(collection, grant)
        try await hydrate(captured, collection, grant); try check(captured, collection, grant)
        if let flight = flights[collection] {
            let id = flightIDs[collection]
            do { try await flight.value; try check(captured, collection, grant); return }
            catch {
                try check(captured, collection, grant); guard AppErrorClassification.isCancellation(error) else { throw error }
                if flightIDs[collection] == id { flights[collection] = nil; flightIDs[collection] = nil }
                try await load(collection, grant: grant, force: force); return
            }
        }
        guard !busy.contains(collection) else { throw GsmFuelError.busy }
        if loaded.contains(collection), !force, !requiresRefresh.contains(collection) { return }
        let id = UUID(); flightIDs[collection] = id; errors[collection] = nil
        let task = Task {
            do {
                let result = try await api.list(collection); try self.check(captured, collection, grant)
                self.values[collection] = result; self.loaded.insert(collection); self.requiresRefresh.remove(collection); self.connections[collection] = .online; self.revisions[collection, default: 0] += 1
                try await self.cache(captured, collection, grant)
            } catch { try self.check(captured, collection, grant); self.record(error, collection); throw error }
        }; flights[collection] = task
        defer { if flightIDs[collection] == id { flights[collection] = nil; flightIDs[collection] = nil } }
        try await task.value; try check(captured, collection, grant)
    }
    private func record(_ error: Error, _ collection: DocumentCollection) {
        errors[collection] = error.localizedDescription
        if case .network = AppErrorClassification.classification(for: error) { connections[collection] = .offline }
        if DomainHTTPClient.isUnauthorized(error) { authFailure() }
    }
    // Reconcile before destructive/replacement writes; uncertain sends are never automatically retried.
    private func mutate(_ collection: DocumentCollection, grant: SalaryAccessGrant?, base: ServerDocument?, salaryMonth: String? = nil, newDocumentID: String? = nil, send: (DocumentService, SessionContext) async throws -> ServerDocument?) async throws -> ServerDocument? {
        let (captured, api) = try capture(collection, grant)
        guard !busy.contains(collection), !requiresRefresh.contains(collection) else { throw AppServiceError.message("Обновите список документов перед повторной отправкой.") }
        busy.insert(collection); var submitted = false
        defer { if bound == captured { busy.remove(collection) } }
        do {
            if let flight = flights[collection] { try await flight.value; try check(captured, collection, grant) }
            let current = try await api.list(collection); try check(captured, collection, grant)
            if let base { guard current.first(where: { $0.id == base.id }) == base else { throw GsmFuelError.conflict } }
            else if let salaryMonth, current.contains(where: { $0.month == salaryMonth }) { throw AppServiceError.message("Расчётный листок за этот месяц уже есть. Выберите его и нажмите «Заменить».") }
            if base == nil, let newDocumentID, current.contains(where: { $0.id == newDocumentID }) { throw AppServiceError.message("Документ уже сохранён. Закройте загрузку; для изменения выберите его в списке и нажмите «Заменить».") }
            values[collection] = current; hydrated.insert(collection)
            submitted = true
            let result = try await send(api, captured); try check(captured, collection, grant)
            if let base { values[collection]?.removeAll { $0.id == base.id } }
            if let result { values[collection]?.removeAll { $0.id == result.id }; values[collection, default: []].append(result) }
            loaded.remove(collection); errors[collection] = nil; revisions[collection, default: 0] += 1
            try await cache(captured, collection, grant); return result
        } catch {
            if bound == captured {
                if submitted, DomainHTTPClient.isUncertain(error) { requiresRefresh.insert(collection) }
                if permits(collection, grant: grant) { record(error, collection); if requiresRefresh.contains(collection) { errors[collection] = "Результат отправки неизвестен. Обновите список перед повтором." } }
            }
            throw error
        }
    }
    public func upload(_ value: DocumentUpload, collection: DocumentCollection, replacing: ServerDocument? = nil, grant: SalaryAccessGrant? = nil, progress: @escaping (Double) -> Void) async throws {
        try value.validate(for: collection)
        if collection == .salary, let replacing, replacing.month != value.month { throw GsmFuelError.conflict }
        _ = try await mutate(collection, grant: grant, base: replacing, salaryMonth: collection == .salary ? value.month : nil, newDocumentID: collection == .salary ? nil : value.id) { api, captured in
            try await api.upload(value, collection: collection, replacing: replacing, check: { try self.check(captured, collection, grant) }, progress: progress)
        }
    }
    public func update(_ base: ServerDocument, category: WorkDocumentCategory, title: String) async throws {
        _ = try await mutate(.work, grant: nil, base: base) { api, _ in try await api.update(base, category: category, title: title) }
    }
    public func delete(_ base: ServerDocument, collection: DocumentCollection, grant: SalaryAccessGrant? = nil) async throws {
        _ = try await mutate(collection, grant: grant, base: base) { api, _ in try await api.delete(base, collection: collection); return nil }
    }
    public func download(_ value: ServerDocument, collection: DocumentCollection, grant: SalaryAccessGrant? = nil) async throws -> URL {
        let (captured, api) = try capture(collection, grant)
        let url: URL
        do { url = try await api.download(value, collection: collection) }
        catch { try check(captured, collection, grant); record(error, collection); throw error }
        do { try check(captured, collection, grant); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
