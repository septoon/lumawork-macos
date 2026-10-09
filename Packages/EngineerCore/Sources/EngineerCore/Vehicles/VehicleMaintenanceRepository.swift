import Foundation
import Observation

@MainActor @Observable
public final class VehicleMaintenanceRepository {
    private struct Vault: Codable { var vehicles: [Vehicle]?; var maintenance: [MaintenanceRecord]? }
    private let sessionProvider: () -> AppSession?
    private let contextProvider: () -> SessionContext?
    private let storageProvider: () throws -> ScopedSnapshotStorage
    private let serviceFactory: (AppSession) -> VehicleMaintenanceService
    private let authFailure: () -> Void
    private var boundContext: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Vault, Error>?
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    private var revision: UInt64 = 0
    private var flight: Task<Void, Error>?
    private var flightID: UUID?
    private var loaded = false
    public private(set) var connection: GsmFuelConnection = .cached
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var requiresRefresh = false
    public private(set) var error: String?
    public private(set) var cacheWarning: String?
    private var active: Bool { boundContext != nil && boundContext == contextProvider() }
    public var vehicles: [Vehicle] { active ? vault.vehicles ?? [] : [] }
    public var maintenance: [MaintenanceRecord] { active ? vault.maintenance ?? [] : [] }
    public var hasSnapshot: Bool { active && vault.vehicles != nil && vault.maintenance != nil }
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage,
                service: @escaping (AppSession) -> VehicleMaintenanceService, authFailure: @escaping () -> Void) {
        sessionProvider = session; contextProvider = context; storageProvider = storage; serviceFactory = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard boundContext != contextProvider() else { return }
        flight?.cancel(); hydration?.cancel(); persistence?.cancel()
        flight = nil; flightID = nil; hydration = nil; persistence = nil; persistenceID = nil
        boundContext = contextProvider(); vault = Vault(); hydrated = false; loaded = false; revision &+= 1
        connection = .cached; isLoading = false; isSaving = false; requiresRefresh = false; error = nil; cacheWarning = nil
    }
    private func capture() throws -> (SessionContext, VehicleMaintenanceService) {
        synchronizeSession()
        guard active, let context = boundContext, let session = sessionProvider(), session.user.id == context.userID else { throw CancellationError() }
        return (context, serviceFactory(session))
    }
    private func check(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard active, boundContext == context else { throw CancellationError() }
    }
    private func handle(_ failure: Error) { if DomainHTTPClient.isUnauthorized(failure) { authFailure() } }
    private func hydrate(_ context: SessionContext) async throws {
        if hydrated { return }
        let task: Task<Vault, Error>
        if let hydration { task = hydration }
        else {
            let storage = try storageProvider(); let scope = try SnapshotScope(userID: context.userID)
            task = Task {
                let data = try await storage.load(key: "vehicles-maintenance.v1", scope: scope)
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
                    try await storage.save(data, key: "vehicles-maintenance.v1", scope: scope); try self.check(context)
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
        if let flight { try await flight.value; try check(context); return }
        guard !isSaving else { throw GsmFuelError.busy }
        if !force, loaded, !requiresRefresh { return }
        let id = UUID(); flightID = id; isLoading = true; error = nil
        let task = Task {
            do {
                async let vehicles = service.vehicles()
                async let maintenance = service.maintenance()
                let result = try await (vehicles, maintenance); try self.check(context)
                self.vault.vehicles = result.0; self.vault.maintenance = result.1
                self.connection = .online; self.loaded = true; self.requiresRefresh = false; self.revision &+= 1
                try await self.cache(context)
            } catch {
                if self.boundContext == context, !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription; if case .network = AppErrorClassification.classification(for: error) { self.connection = .offline }; self.handle(error) }
                throw error
            }
        }; flight = task
        defer { if flightID == id { flight = nil; flightID = nil; isLoading = false } }
        try await task.value; try check(context)
    }
    private func begin(_ context: SessionContext) async throws {
        try check(context)
        guard !isSaving, !requiresRefresh else { throw AppServiceError.message("Обновите данные перед повторной отправкой.") }
        isSaving = true
        if let flight { do { try await flight.value; try check(context) } catch { if boundContext == context { isSaving = false }; throw error } }
    }
    private func mutationFailed(_ failure: Error, context: SessionContext, submitted: Bool) {
        guard boundContext == context else { return }
        if submitted && DomainHTTPClient.isUncertain(failure) { requiresRefresh = true; error = "Результат отправки неизвестен. Обновите данные перед повтором." }
        else if !AppErrorClassification.isCancellation(failure) { error = failure.localizedDescription }
        handle(failure)
    }
    public func saveVehicle(_ draft: VehicleDraft, base: Vehicle?, expectedContext: SessionContext) async throws -> Vehicle {
        let (context, service) = try capture(); guard context == expectedContext else { throw CancellationError() }
        _ = try draft.payload(); try await hydrate(context); try check(context); try await begin(context)
        defer { if boundContext == context { isSaving = false } }
        var submitted = false
        do {
            if let base {
                let current = try await service.vehicles(); try check(context)
                guard current.first(where: { $0.id == base.id }) == base else { throw GsmFuelError.conflict }
            }
            submitted = true
            let saved = try await service.saveVehicle(draft, id: base?.id); try check(context)
            var rows = vault.vehicles ?? []; rows.removeAll { $0.id == saved.id }
            if saved.isPrimary { rows = rows.map { var value = $0; value.isPrimary = false; return value } }
            rows.append(saved); vault.vehicles = rows; revision &+= 1; loaded = false; error = nil
            try await cache(context); return saved
        } catch { mutationFailed(error, context: context, submitted: submitted); throw error }
    }
    public func saveMaintenance(_ input: MaintenanceRecordInput, base: MaintenanceRecord?, expectedContext: SessionContext) async throws -> MaintenanceRecord {
        let (context, service) = try capture(); guard context == expectedContext else { throw CancellationError() }
        _ = try VehicleMaintenanceService.maintenancePayload(input); try await hydrate(context); try check(context); try await begin(context)
        defer { if boundContext == context { isSaving = false } }
        var submitted = false
        do {
            guard input.vehicleID.map({ id in vehicles.contains { $0.id == id } }) ?? (vehicles.count <= 1) else { throw GsmFuelError.conflict }
            if let base {
                guard base.id != nil else { throw GsmFuelError.conflict }
                let current = try await service.maintenance(); try check(context)
                guard current.first(where: { $0.id == base.id }) == base else { throw GsmFuelError.conflict }
            }
            submitted = true
            let saved = try await service.saveMaintenance(input, id: base?.id); try check(context)
            var rows = vault.maintenance ?? []; rows.removeAll { $0.id == saved.id }; rows.append(saved)
            vault.maintenance = rows; revision &+= 1; loaded = false; error = nil; try await cache(context); return saved
        } catch { mutationFailed(error, context: context, submitted: submitted); throw error }
    }
    public func deleteMaintenance(_ base: MaintenanceRecord, expectedContext: SessionContext) async throws {
        let (context, service) = try capture(); guard context == expectedContext, let id = base.id else { throw GsmFuelError.conflict }
        try await hydrate(context); try check(context); try await begin(context)
        defer { if boundContext == context { isSaving = false } }
        var submitted = false
        do {
            let current = try await service.maintenance(); try check(context)
            guard current.first(where: { $0.id == id }) == base else { throw GsmFuelError.conflict }
            submitted = true; try await service.deleteMaintenance(id); try check(context)
            vault.maintenance?.removeAll { $0.id == id }; revision &+= 1; loaded = false; error = nil; try await cache(context)
        } catch { mutationFailed(error, context: context, submitted: submitted); throw error }
    }
}
