import Foundation
import Observation

@MainActor @Observable
public final class RequestsRepository {
    private struct Snapshot: Codable { var records: [SimpleOneRequestRecord]; var updatedAt: Date }
    private struct Detail: Codable { var record: SimpleOneRequestRecord; var fetchedAt: Date }
    private struct Vault: Codable { var lists: [SimpleOneRequestSource: Snapshot] = [:]; var details: [String: Detail] = [:] }
    private let session: () -> SimpleOneSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: () -> any SimpleOneRequestsServing
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Vault, Error>?
    private var flights: [SimpleOneRequestSource: Task<Void, Error>] = [:]
    private var flightIDs: [SimpleOneRequestSource: UUID] = [:]
    private var detailFlights: [String: Task<SimpleOneRequestRecord, Error>] = [:]
    private var detailIDs: [String: UUID] = [:]
    private var loaded: Set<SimpleOneRequestSource> = []
    private var revision: UInt64 = 0
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    public private(set) var loading: Set<SimpleOneRequestSource> = []
    public private(set) var offline: Set<SimpleOneRequestSource> = []
    public private(set) var errors: [SimpleOneRequestSource: String] = [:]
    public private(set) var cacheWarning: String?
    private var active: Bool { bound != nil && bound == context() && session()?.user.sysID == bound?.simpleOneUserID }

    public init(session: @escaping () -> SimpleOneSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping () -> any SimpleOneRequestsServing, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        hydration?.cancel(); persistence?.cancel(); flights.values.forEach { $0.cancel() }; detailFlights.values.forEach { $0.cancel() }
        bound = context(); vault = Vault(); hydrated = false; hydration = nil; persistence = nil; persistenceID = nil
        flights = [:]; flightIDs = [:]; detailFlights = [:]; detailIDs = [:]; loaded = []; loading = []; offline = []; errors = [:]; cacheWarning = nil; revision &+= 1
    }
    private func capture() throws -> (SessionContext, SimpleOneSession) {
        synchronizeSession()
        guard active, let bound, let session = session() else { throw SimpleOneServiceError.missingCredentials }
        return (bound, session)
    }
    private func check(_ captured: SessionContext) throws {
        try Task.checkCancellation()
        guard active, bound == captured else { throw CancellationError() }
    }
    private func scope(_ captured: SessionContext) throws -> SnapshotScope {
        try SnapshotScope(userID: captured.userID, simpleOneUserID: captured.simpleOneUserID)
    }
    public func records(_ source: SimpleOneRequestSource) -> [SimpleOneRequestRecord] { active ? vault.lists[source]?.records ?? [] : [] }
    public func hasSnapshot(_ source: SimpleOneRequestSource) -> Bool { active && vault.lists[source] != nil }
    public func updatedAt(_ source: SimpleOneRequestSource) -> Date? { active ? vault.lists[source]?.updatedAt : nil }
    public func prepare() async throws {
        let (captured, _) = try capture()
        if hydrated { return }
        let task: Task<Vault, Error>
        if let hydration { task = hydration }
        else {
            let disk = try storage(), scope = try scope(captured)
            task = Task {
                let data = try await disk.load(key: "requests.v1", scope: scope); try self.check(captured)
                return try data.map { try JSONDecoder().decode(Vault.self, from: $0) } ?? Vault()
            }; hydration = task
        }
        do {
            let result = try await task.value; try check(captured)
            if !hydrated { vault = result; hydrated = true; hydration = nil }
        } catch {
            try check(captured)
            hydration = nil; hydrated = true; cacheWarning = error.localizedDescription
            // Corrupt/unavailable disk storage must not prevent an explicit network refresh.
        }
    }
    private func persist(_ captured: SessionContext) async throws {
        try check(captured)
        let task: Task<Void, Error>
        if let persistence { task = persistence }
        else {
            persistenceID = UUID()
            let disk = try storage(), scope = try scope(captured)
            task = Task {
                repeat {
                    try self.check(captured); let written = self.revision, data = try JSONEncoder().encode(self.vault)
                    try await disk.save(data, key: "requests.v1", scope: scope); try self.check(captured)
                    if written == self.revision { break }
                } while true
            }; persistence = task
        }
        let id = persistenceID
        do { try await task.value; try check(captured); if id == persistenceID { persistence = nil; persistenceID = nil; cacheWarning = nil } }
        catch { if id == persistenceID { persistence = nil; persistenceID = nil }; throw error }
    }
    public func load(_ source: SimpleOneRequestSource, force: Bool = false) async throws {
        let (captured, credentials) = try capture(); try await prepare(); try check(captured)
        if !force, loaded.contains(source) { return }
        if let flight = flights[source] { try await flight.value; try check(captured); return }
        let id = UUID(); flightIDs[source] = id; loading.insert(source); errors[source] = nil
        let api = service()
        let task = Task {
            do {
                let records = try await api.fetch(source: source, userID: credentials.user.sysID, authKey: credentials.authKey); try self.check(captured)
                self.vault.lists[source] = Snapshot(records: records, updatedAt: Date()); self.revision &+= 1
                let versions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.sysUpdatedAt ?? "") })
                self.vault.details = self.vault.details.filter { key, value in
                    value.record.source != source || versions[key] == (value.record.sysUpdatedAt ?? "")
                }
                self.loaded.insert(source); self.offline.remove(source)
                do { try await self.persist(captured) }
                catch { try self.check(captured); self.cacheWarning = "Данные загружены, но кеш не сохранён: " + error.localizedDescription }
                try self.check(captured)
            } catch {
                if self.bound == captured, !AppErrorClassification.isCancellation(error) {
                    self.errors[source] = error.localizedDescription
                    if case .network = AppErrorClassification.classification(for: error) { self.offline.insert(source) }
                    self.handleAuth(error)
                }
                throw error
            }
        }; flights[source] = task
        defer { if flightIDs[source] == id { flights[source] = nil; flightIDs[source] = nil; loading.remove(source) } }
        try await task.value; try check(captured)
    }
    public func cachedDetail(_ record: SimpleOneRequestRecord) -> SimpleOneRequestRecord {
        guard active, let cached = vault.details[record.id], (cached.record.sysUpdatedAt ?? "") >= (record.sysUpdatedAt ?? "") else { return record }
        return cached.record
    }
    public func detail(_ record: SimpleOneRequestRecord, force: Bool = false) async throws -> SimpleOneRequestRecord {
        let (captured, credentials) = try capture(); try await prepare(); try check(captured)
        if !force, let cached = vault.details[record.id], Date().timeIntervalSince(cached.fetchedAt) < 600,
           (cached.record.sysUpdatedAt ?? "") >= (record.sysUpdatedAt ?? "") { return cached.record }
        if let flight = detailFlights[record.id] { let value = try await flight.value; try check(captured); return value }
        let id = UUID(), api = service(); detailIDs[record.id] = id
        let task = Task {
            do {
                let result = try await api.detail(record: record, authKey: credentials.authKey); try self.check(captured)
                guard result.sysID == record.sysID else { throw SimpleOneServiceError.invalidResponse }
                if let current = self.vault.lists[record.source]?.records.first(where: { $0.id == record.id }),
                   (current.sysUpdatedAt ?? "") > (result.sysUpdatedAt ?? "") { return current }
                self.vault.details[record.id] = Detail(record: result, fetchedAt: Date())
                if self.vault.details.count > 200 {
                    self.vault.details = Dictionary(uniqueKeysWithValues: self.vault.details.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(200).map { ($0.key, $0.value) })
                }
                self.revision &+= 1
                do { try await self.persist(captured) } catch { try self.check(captured); self.cacheWarning = error.localizedDescription }
                try self.check(captured); return result
            } catch { if self.bound == captured { self.handleAuth(error) }; throw error }
        }; detailFlights[record.id] = task
        defer { if detailIDs[record.id] == id { detailIDs[record.id] = nil; detailFlights[record.id] = nil } }
        let result = try await task.value; try check(captured); return result
    }
    private func handleAuth(_ error: Error) {
        if let error = error as? SimpleOneServiceError, case .unauthorized = error { authFailure(); synchronizeSession() }
    }
}
