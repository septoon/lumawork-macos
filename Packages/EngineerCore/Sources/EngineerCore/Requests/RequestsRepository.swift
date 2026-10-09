import Foundation
import Observation

@MainActor @Observable
public final class RequestsRepository {
    private struct Snapshot: Codable { var records: [SimpleOneRequestRecord]; var updatedAt: Date }
    private struct Detail: Codable { var record: SimpleOneRequestRecord; var fetchedAt: Date }
    private struct TimeSnapshot: Codable { var entries: [TimeReportEntry]; var updatedAt: Date }
    private struct Vault: Codable {
        var lists: [SimpleOneRequestSource: Snapshot] = [:]
        var details: [String: Detail] = [:]
        var extraLists: [String: Snapshot]?
        var timeReports: TimeSnapshot?
    }
    private let session: () -> SimpleOneSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: () -> any SimpleOneRequestsServing
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Vault, Error>?
    private var flights: [RequestCollection: Task<Void, Error>] = [:]
    private var flightIDs: [RequestCollection: UUID] = [:]
    private var timeFlight: Task<Void, Error>?
    private var timeFlightID: UUID?
    private var loadedTime = false
    public private(set) var isLoadingTime = false
    public private(set) var timeOffline = false
    public private(set) var timeError: String?
    private var detailFlights: [String: Task<SimpleOneRequestRecord, Error>] = [:]
    private var detailIDs: [String: UUID] = [:]
    private var loaded: Set<RequestCollection> = []
    private var revision: UInt64 = 0
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    public private(set) var loading: Set<RequestCollection> = []
    public private(set) var offline: Set<RequestCollection> = []
    public private(set) var errors: [RequestCollection: String] = [:]
    public private(set) var cacheWarning: String?
    private var active: Bool { bound != nil && bound == context() && session()?.user.sysID == bound?.simpleOneUserID }

    public init(session: @escaping () -> SimpleOneSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping () -> any SimpleOneRequestsServing, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        hydration?.cancel(); persistence?.cancel(); timeFlight?.cancel(); flights.values.forEach { $0.cancel() }; detailFlights.values.forEach { $0.cancel() }
        timeFlight = nil; timeFlightID = nil; loadedTime = false; isLoadingTime = false; timeOffline = false; timeError = nil
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
    private func snapshot(_ collection: RequestCollection) -> Snapshot? {
        if case .personal(let source) = collection { return vault.lists[source] }
        return vault.extraLists?[collection.key]
    }
    public func records(_ collection: RequestCollection) -> [SimpleOneRequestRecord] { active ? snapshot(collection)?.records ?? [] : [] }
    public func hasSnapshot(_ collection: RequestCollection) -> Bool { active && snapshot(collection) != nil }
    public func updatedAt(_ collection: RequestCollection) -> Date? { active ? snapshot(collection)?.updatedAt : nil }
    public func records(_ source: SimpleOneRequestSource) -> [SimpleOneRequestRecord] { records(.personal(source)) }
    public func hasSnapshot(_ source: SimpleOneRequestSource) -> Bool { hasSnapshot(.personal(source)) }
    public func updatedAt(_ source: SimpleOneRequestSource) -> Date? { updatedAt(.personal(source)) }
    public var timeEntries: [TimeReportEntry] { active ? vault.timeReports?.entries ?? [] : [] }
    public var timeUpdatedAt: Date? { active ? vault.timeReports?.updatedAt : nil }
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
    public func load(_ source: SimpleOneRequestSource, force: Bool = false) async throws { try await load(.personal(source), force: force) }
    public func load(_ collection: RequestCollection, force: Bool = false) async throws {
        let (captured, credentials) = try capture(); try await prepare(); try check(captured)
        if !force, loaded.contains(collection) { return }
        if let flight = flights[collection] { try await flight.value; try check(captured); return }
        let id = UUID(); flightIDs[collection] = id; loading.insert(collection); errors[collection] = nil
        let api = service()
        let task = Task {
            do {
                let records = try await api.fetch(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey); try self.check(captured)
                let snapshot = Snapshot(records: records, updatedAt: Date())
                if case .personal(let source) = collection { self.vault.lists[source] = snapshot }
                else { if self.vault.extraLists == nil { self.vault.extraLists = [:] }; self.vault.extraLists?[collection.key] = snapshot }
                self.revision &+= 1
                for record in records {
                    if let cached = self.vault.details[record.id], cached.record.sysUpdatedAt != record.sysUpdatedAt { self.vault.details[record.id] = nil }
                }
                self.loaded.insert(collection); self.offline.remove(collection)
                do { try await self.persist(captured) }
                catch { try self.check(captured); self.cacheWarning = "Данные загружены, но кеш не сохранён: " + error.localizedDescription }
                try self.check(captured)
            } catch {
                if self.bound == captured, !AppErrorClassification.isCancellation(error) {
                    self.errors[collection] = error.localizedDescription
                    if case .network = AppErrorClassification.classification(for: error) { self.offline.insert(collection) }
                    self.handleAuth(error)
                }
                throw error
            }
        }; flights[collection] = task
        defer { if flightIDs[collection] == id { flights[collection] = nil; flightIDs[collection] = nil; loading.remove(collection) } }
        try await task.value; try check(captured)
    }
    public func cachedDetail(_ record: SimpleOneRequestRecord) -> SimpleOneRequestRecord {
        guard active, let cached = vault.details[record.id], let version = record.sysUpdatedAt, !version.isEmpty, cached.record.sysUpdatedAt == version else { return record }
        var value = cached.record; value.source = record.source; return value
    }
    public func detail(_ record: SimpleOneRequestRecord, force: Bool = false) async throws -> SimpleOneRequestRecord {
        let (captured, credentials) = try capture(); try await prepare(); try check(captured)
        if !force, let cached = vault.details[record.id], Date().timeIntervalSince(cached.fetchedAt) < 600,
           let version = record.sysUpdatedAt, !version.isEmpty, cached.record.sysUpdatedAt == version { return cachedDetail(record) }
        if let flight = detailFlights[record.id] { var value = try await flight.value; try check(captured); value.source = record.source; return value }
        let id = UUID(), api = service(); detailIDs[record.id] = id
        let task = Task {
            do {
                let result = try await api.detail(record: record, authKey: credentials.authKey); try self.check(captured)
                guard result.sysID == record.sysID else { throw SimpleOneServiceError.invalidResponse }
                if let current = (Array(self.vault.lists.values) + Array((self.vault.extraLists ?? [:]).values)).flatMap(\.records).filter({ $0.id == record.id }).max(by: { ($0.sysUpdatedAt ?? "") < ($1.sysUpdatedAt ?? "") }),
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
        var result = try await task.value; try check(captured); result.source = record.source; return result
    }
    public func loadTimeReports(force: Bool = false) async throws {
        let (captured, credentials) = try capture(); try await prepare(); try check(captured)
        if !force, loadedTime { return }
        if let timeFlight { try await timeFlight.value; try check(captured); return }
        let id = UUID(), api = service(); timeFlightID = id; isLoadingTime = true; timeError = nil
        let task = Task {
            do {
                let entries = try await api.fetchTimeReports(authKey: credentials.authKey); try self.check(captured)
                self.vault.timeReports = TimeSnapshot(entries: TimeReportPolicy.merge(existing: self.vault.timeReports?.entries ?? [], incoming: entries), updatedAt: Date())
                self.loadedTime = true; self.timeOffline = false; self.revision &+= 1
                do { try await self.persist(captured) } catch { try self.check(captured); self.cacheWarning = error.localizedDescription }
                try self.check(captured)
            } catch {
                if self.bound == captured, !AppErrorClassification.isCancellation(error) {
                    self.timeError = error.localizedDescription
                    if case .network = AppErrorClassification.classification(for: error) { self.timeOffline = true }
                    self.handleAuth(error)
                }
                throw error
            }
        }; timeFlight = task
        defer { if timeFlightID == id { timeFlight = nil; timeFlightID = nil; isLoadingTime = false } }
        try await task.value; try check(captured)
    }
    private func handleAuth(_ error: Error) {
        if let error = error as? SimpleOneServiceError, case .unauthorized = error { authFailure(); synchronizeSession() }
    }
}
