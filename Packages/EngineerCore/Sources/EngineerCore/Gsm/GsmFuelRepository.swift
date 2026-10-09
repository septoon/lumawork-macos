import Foundation
import Observation

public enum GsmFuelConnection { case cached, online, offline }
@MainActor @Observable
public final class GsmFuelRepository {
    private struct Vault: Codable {
        var records: [FuelRecord]?
        var profile: GsmProfileLoadResult?
        var projects: [GsmProjectOption] = []
    }
    private let sessionProvider: () -> AppSession?
    private let contextProvider: () -> SessionContext?
    private let storageProvider: () throws -> ScopedSnapshotStorage
    private let serviceFactory: (AppSession) -> any GsmFuelServing
    private let authFailure: () -> Void
    private var boundContext: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Vault, Error>?
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var fuelFlight: Task<Void, Error>?
    private var gsmFlight: Task<Void, Error>?
    private var fuelFlightID: UUID?
    private var gsmFlightID: UUID?
    private var loadedFuel = false
    private var loadedGsm = false
    public private(set) var isLoadingFuel = false
    public private(set) var isLoadingGsm = false
    public private(set) var isMutating = false
    public private(set) var requiresAuthentication = false
    public private(set) var fuelConnection: GsmFuelConnection = .cached
    public private(set) var gsmConnection: GsmFuelConnection = .cached
    public private(set) var fuelError: String?
    public private(set) var gsmError: String?
    public private(set) var cacheWarning: String?
    public var records: [FuelRecord] { active ? vault.records ?? [] : [] }
    public var hasFuelSnapshot: Bool { active && vault.records != nil }
    public var profile: GsmProfileLoadResult? { active ? vault.profile : nil }
    public var projects: [GsmProjectOption] { active ? vault.projects : [] }
    private var active: Bool { boundContext != nil && boundContext == contextProvider() && !requiresAuthentication }
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> any GsmFuelServing, authFailure: @escaping () -> Void = {}) {
        sessionProvider = session; contextProvider = context; storageProvider = storage; serviceFactory = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard boundContext != contextProvider() else { return }
        fuelFlight?.cancel(); gsmFlight?.cancel(); hydration?.cancel(); persistence?.cancel()
        fuelFlight = nil; gsmFlight = nil; hydration = nil; persistence = nil; persistenceID = nil
        fuelFlightID = nil; gsmFlightID = nil; vault = Vault(); hydrated = false
        loadedFuel = false; loadedGsm = false; isLoadingFuel = false; isLoadingGsm = false; isMutating = false
        requiresAuthentication = false; fuelConnection = .cached; gsmConnection = .cached; fuelError = nil; gsmError = nil; cacheWarning = nil
        boundContext = contextProvider(); revision &+= 1; generation &+= 1
    }
    private func capture() throws -> (SessionContext, any GsmFuelServing) {
        synchronizeSession()
        guard active, let context = boundContext, let session = sessionProvider(), context.userID == session.user.id else { throw GsmFuelError.staleSession }
        return (context, serviceFactory(session))
    }
    private func check(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard active, boundContext == context else { throw GsmFuelError.staleSession }
    }
    private func hydrate(_ context: SessionContext) async throws {
        if hydrated { return }
        let task: Task<Vault, Error>
        if let hydration { task = hydration }
        else {
            let storage = try storageProvider(); let scope = try SnapshotScope(userID: context.userID)
            task = Task {
                let data = try await storage.load(key: "gsm-fuel.v1", scope: scope)
                try self.check(context)
                return try data.map { try JSONDecoder().decode(Vault.self, from: $0) } ?? Vault()
            }; hydration = task
        }
        do {
            let value = try await task.value; try check(context)
            if !hydrated { vault = value; hydrated = true; hydration = nil }
        } catch { if boundContext == context { hydration = nil }; throw error }
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
                    try await storage.save(data, key: "gsm-fuel.v1", scope: scope); try self.check(context)
                    if written == self.revision { break }
                } while true
            }; persistence = task
        }
        let id = persistenceID
        do { try await task.value; try check(context); if persistenceID == id { persistence = nil; persistenceID = nil } }
        catch { if persistenceID == id { persistence = nil; persistenceID = nil }; throw error }
    }
    public func prepare() async throws { let (context, _) = try capture(); try await hydrate(context); try check(context) }
    public func loadFuel(force: Bool = false) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        if !force, loadedFuel { return }
        if let flight = fuelFlight { try await flight.value; try check(context); return }
        guard !isMutating else { throw GsmFuelError.busy }
        let id = UUID(), currentGeneration = generation; fuelFlightID = id; isLoadingFuel = true; fuelError = nil
        let task = Task {
            do {
                let records = try await service.fetchFuel(); try self.check(context)
                guard self.generation == currentGeneration else { throw CancellationError() }
                self.vault.records = records; self.loadedFuel = true; self.fuelConnection = .online; self.revision &+= 1
                try await self.persist(context)
                guard self.generation == currentGeneration else { throw CancellationError() }
            } catch {
                if self.boundContext == context, !AppErrorClassification.isCancellation(error) {
                    self.handle(error); self.fuelError = error.localizedDescription
                    if Self.isOffline(error) { self.fuelConnection = .offline }
                }; throw error
            }
        }; fuelFlight = task
        defer { if fuelFlightID == id { fuelFlight = nil; fuelFlightID = nil; isLoadingFuel = false } }
        try await task.value; try check(context)
    }
    public func loadGsm(force: Bool = false) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        if !force, loadedGsm { return }
        if let flight = gsmFlight { try await flight.value; try check(context); return }
        guard !isMutating else { throw GsmFuelError.busy }
        let id = UUID(), currentGeneration = generation; gsmFlightID = id; isLoadingGsm = true; gsmError = nil
        let task = Task {
            do {
                let profile = try await service.fetchProfile(); try self.check(context)
                let projects = try await service.fetchProjects(); try self.check(context)
                guard self.generation == currentGeneration else { throw CancellationError() }
                self.vault.profile = profile; self.vault.projects = projects; self.loadedGsm = true; self.gsmConnection = .online; self.revision &+= 1
                try await self.persist(context)
                guard self.generation == currentGeneration else { throw CancellationError() }
            } catch {
                if self.boundContext == context, !AppErrorClassification.isCancellation(error) {
                    self.handle(error); self.gsmError = error.localizedDescription
                    if Self.isOffline(error) { self.gsmConnection = .offline }
                }; throw error
            }
        }; gsmFlight = task
        defer { if gsmFlightID == id { gsmFlight = nil; gsmFlightID = nil; isLoadingGsm = false } }
        try await task.value; try check(context)
    }
    private func beginMutation() throws {
        guard !isMutating else { throw GsmFuelError.busy }
        isMutating = true; generation &+= 1
        fuelFlight?.cancel(); gsmFlight?.cancel()
    }
    private func finishMutation(_ context: SessionContext) { if boundContext == context { isMutating = false } }
    private func cacheAfterWrite(_ context: SessionContext) async throws {
        revision &+= 1
        do { try await persist(context); cacheWarning = nil }
        catch {
            try check(context)
            // The server write is already confirmed; never report it as an unsent operation or auto-repeat it.
            cacheWarning = "Сервер подтвердил сохранение, но локальный кеш записать не удалось. " + error.localizedDescription
        }
        try check(context)
    }
    public func saveFuel(_ draft: FuelRecord, base: FuelRecord?) async throws -> FuelRecord {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        _ = try FuelWire.payload(draft)
        guard draft.id == base?.id else { throw GsmFuelError.conflict }
        try beginMutation(); defer { finishMutation(context) }
        do {
            if let base {
                guard vault.records?.first(where: { $0.id == base.id }) == base else { throw GsmFuelError.conflict }
                let current = try await service.fetchFuel(); try check(context)
                guard current.first(where: { $0.id == base.id }) == base else { throw GsmFuelError.conflict }
            }
            let saved = try await service.saveFuel(draft); try check(context)
            if vault.records == nil { vault.records = [] }
            vault.records?.removeAll { $0.id == saved.id }; vault.records?.append(saved)
            loadedFuel = false; fuelConnection = .online
            try await cacheAfterWrite(context); return saved
        } catch { if boundContext == context { handle(error) }; throw error }
    }
    public func deleteFuel(_ record: FuelRecord) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        guard let id = record.id, vault.records?.first(where: { $0.id == id }) == record else { throw GsmFuelError.conflict }
        try beginMutation(); defer { finishMutation(context) }
        do {
            let current = try await service.fetchFuel(); try check(context)
            guard current.first(where: { $0.id == id }) == record else { throw GsmFuelError.conflict }
            try await service.deleteFuel(id: id); try check(context)
            vault.records?.removeAll { $0.id == id }; loadedFuel = false
            try await cacheAfterWrite(context)
        } catch { if boundContext == context { handle(error) }; throw error }
    }
    public func saveProfile(_ draft: GsmProfile, base: GsmProfile) async throws -> GsmProfileLoadResult {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        _ = try GsmWire.profilePayload(draft)
        guard vault.profile?.profile == base else { throw GsmFuelError.conflict }
        try beginMutation(); defer { finishMutation(context) }
        do {
            let current = try await service.fetchProfile(); try check(context)
            guard current.profile == base else { throw GsmFuelError.conflict }
            let saved = try await service.saveProfile(draft); try check(context)
            vault.profile = saved; loadedGsm = false; gsmConnection = .online
            try await cacheAfterWrite(context); return saved
        } catch { if boundContext == context { handle(error) }; throw error }
    }
    public func syncMonthlyMileage(_ mileage: RouteMonthlyMileage) async throws -> FuelRecord? {
        let (context, _) = try capture()
        try await loadFuel(force: true); try check(context)
        let target = FuelWire.monthlyMileageIndex(records: records, month: mileage.monthKey).map { records[$0] }
        let record = mileage.record(replacing: target)
        if record == target || mileage.totalKm == 0 && target == nil { return target }
        return try await saveFuel(record, base: target)
    }
    public func sendReport(month: String) async throws -> GsmReportResponse {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        try beginMutation(); defer { finishMutation(context) }
        do { let result = try await service.sendReport(month: month); try check(context); return result }
        catch { if boundContext == context { handle(error) }; throw error }
    }
    public func startOdometer(month: String) async throws -> Int? {
        let (context, service) = try capture()
        do { let value = try await service.fetchStartOdometer(month: month); try check(context); return value }
        catch { if boundContext == context { handle(error) }; throw error }
    }
    private func handle(_ error: Error) {
        if case GsmFuelError.unauthorized = error {
            requiresAuthentication = true; vault = Vault(); generation &+= 1
            fuelFlight?.cancel(); gsmFlight?.cancel(); hydration?.cancel(); persistence?.cancel(); authFailure()
        }
    }
    private static func isOffline(_ error: Error) -> Bool {
        if case GsmFuelError.infrastructure = error { return true }
        if case GsmFuelError.http(let status, _) = error { return [502, 503, 504].contains(status) }
        return false
    }
}
