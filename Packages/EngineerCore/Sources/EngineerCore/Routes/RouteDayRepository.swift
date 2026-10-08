import Foundation
import Observation

public struct RouteSavedDraft: Codable, Hashable, Sendable {
    public var record: RouteDayRecord
    public var base: RouteDayRecord?
    public var revision: UUID
    public var queued: Bool
}
public enum RouteConnection: Sendable { case cached, online, offline }
public struct RouteDaySnapshot: Sendable {
    public let remote: RouteDayRecord?
    public let draft: RouteSavedDraft?
    public let connection: RouteConnection
}
public enum RouteRepositoryError: LocalizedError {
    case conflict, localConflict, busy, staleSession
    case queued(String)
    public var errorDescription: String? {
        switch self {
        case .conflict: "Маршрут на сервере изменился. Черновик сохранён; сравните его с актуальным маршрутом перед отправкой."
        case .localConflict: "В другом окне сохранён новый черновик этого дня. Обновите данные перед сохранением."
        case .busy: "Этот маршрут уже отправляется."
        case .staleSession: "Сессия изменилась. Откройте маршрут снова."
        case .queued(let message): "\(message) Маршрут сохранён в очереди; повторите отправку после восстановления связи."
        }
    }
}

@MainActor @Observable
public final class RouteDayRepository {
    private struct Vault: Codable {
        var remote: [String: RouteDayRecord] = [:]
        var drafts: [String: RouteSavedDraft] = [:]
    }
    private struct Flight { let id: UUID; let task: Task<RouteDayRecord?, Error> }
    private let sessionProvider: () -> AppSession?
    private let contextProvider: () -> SessionContext?
    private let storageProvider: () throws -> ScopedSnapshotStorage
    private let serviceFactory: (AppSession) -> any RouteDayServing
    private let authFailure: () -> Void
    private var boundContext: SessionContext?
    private var vault = Vault()
    private var loadedKeys = Set<String>()
    private var connections: [String: RouteConnection] = [:]
    private var flights: [RouteDayKey: Flight] = [:]
    private var hydration: Task<Vault, Error>?
    private var hydrated = false
    private var persistence: Task<Void, Error>?
    private var persistenceID: UUID?
    private var revision: UInt64 = 0
    private var remoteGeneration: UInt64 = 0
    private var dayGenerations: [RouteDayKey: UInt64] = [:]
    private var sending = Set<RouteDayKey>()
    public private(set) var requiresAuthentication = false
    public private(set) var archiveConnection: RouteConnection = .cached
    public private(set) var archiveError: String?
    public private(set) var isLoadingArchive = false
    private var archiveFlight: Task<[RouteDayRecord], Error>?
    public private(set) var officeAddresses: [String] = []

    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage,
                service: @escaping (AppSession) -> any RouteDayServing, authFailure: @escaping () -> Void = {}) {
        sessionProvider = session; contextProvider = context; storageProvider = storage; serviceFactory = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard boundContext != contextProvider() else { return }
        flights.values.forEach { $0.task.cancel() }; flights = [:]
        hydration?.cancel(); hydration = nil; persistence?.cancel(); persistence = nil; persistenceID = nil
        archiveFlight?.cancel(); archiveFlight = nil; isLoadingArchive = false
        vault = Vault(); loadedKeys = []; connections = [:]; sending = []; hydrated = false
        requiresAuthentication = false; archiveConnection = .cached; archiveError = nil; officeAddresses = []
        boundContext = contextProvider(); revision &+= 1; remoteGeneration &+= 1
        dayGenerations = [:]
    }
    private var active: Bool { boundContext != nil && boundContext == contextProvider() && !requiresAuthentication }
    public func snapshot(for key: RouteDayKey) -> RouteDaySnapshot? {
        guard active, loadedKeys.contains(key.storageKey) || vault.remote[key.storageKey] != nil || vault.drafts[key.storageKey] != nil else { return nil }
        return RouteDaySnapshot(remote: vault.remote[key.storageKey], draft: vault.drafts[key.storageKey], connection: connections[key.storageKey] ?? .cached)
    }
    public var archive: [RouteDayRecord] { active ? vault.remote.values.sorted { ($0.date, $0.workType.rawValue) > ($1.date, $1.workType.rawValue) } : [] }
    public func isSending(_ key: RouteDayKey) -> Bool { active && sending.contains(key) }
    public var settings: RouteSettings {
        RouteSettings(warehouseAddress: sessionProvider()?.user.profile?.routeWarehouseAddress ?? RouteSettings.officeAddress,
                      homeAddress: sessionProvider()?.user.profile?.routeHomeAddress ?? "")
    }
    private func capture() throws -> (SessionContext, any RouteDayServing) {
        synchronizeSession()
        guard active, let context = boundContext, let session = sessionProvider(), session.user.id == context.userID else { throw RouteRepositoryError.staleSession }
        return (context, serviceFactory(session))
    }
    private func check(_ context: SessionContext) throws {
        try Task.checkCancellation()
        guard active, boundContext == context else { throw RouteRepositoryError.staleSession }
    }
    private func hydrate(_ context: SessionContext) async throws {
        if hydrated { return }
        let task: Task<Vault, Error>
        if let hydration { task = hydration }
        else {
            let storage = try storageProvider(); let scope = try SnapshotScope(userID: context.userID)
            task = Task {
                let data = try await storage.load(key: "routes.v1", scope: scope)
                try self.check(context)
                return try data.map { try JSONDecoder().decode(Vault.self, from: $0) } ?? Vault()
            }
            hydration = task
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
                    try self.check(context)
                    let written = self.revision
                    let data = try JSONEncoder().encode(self.vault)
                    try await storage.save(data, key: "routes.v1", scope: scope)
                    try self.check(context)
                    if written == self.revision { break }
                } while true
            }
            persistence = task
        }
        let id = persistenceID
        do { try await task.value; try check(context); if persistenceID == id { persistence = nil; persistenceID = nil } }
        catch { if persistenceID == id { persistence = nil; persistenceID = nil }; throw error }
    }
    public func prepare(_ key: RouteDayKey) async throws -> RouteDaySnapshot? {
        let (context, _) = try capture()
        try await hydrate(context); try check(context)
        return snapshot(for: key)
    }
    public func load(_ key: RouteDayKey, force: Bool = false) async throws -> RouteDayRecord? {
        let (context, service) = try capture()
        try await hydrate(context); try check(context)
        if !force, loadedKeys.contains(key.storageKey) { return vault.remote[key.storageKey] }
        if let flight = flights[key] { return try await flight.task.value }
        let id = UUID(); let generation = dayGenerations[key, default: 0]; let settings = self.settings
        let task = Task<RouteDayRecord?, Error> {
            do {
                let remote = try await service.fetchDay(date: key.date, workType: key.workType, settings: settings)
                try self.check(context)
                guard generation == self.dayGenerations[key, default: 0] else { throw CancellationError() }
                self.vault.remote[key.storageKey] = remote
                self.loadedKeys.insert(key.storageKey); self.connections[key.storageKey] = .online; self.revision &+= 1
                try await self.persist(context)
                return remote
            } catch {
                guard self.boundContext == context, !AppErrorClassification.isCancellation(error) else { throw error }
                self.handle(error)
                if self.active, Self.isOffline(error) { self.connections[key.storageKey] = .offline }
                throw error
            }
        }
        flights[key] = Flight(id: id, task: task)
        defer { if flights[key]?.id == id { flights[key] = nil } }
        return try await task.value
    }
    public func saveLocal(_ record: RouteDayRecord, base: RouteDayRecord?, replacing revision: UUID?) async throws -> RouteSavedDraft {
        let (context, _) = try capture()
        try await hydrate(context); try check(context)
        let key = record.key.storageKey
        guard vault.drafts[key]?.revision == revision else { throw RouteRepositoryError.localConflict }
        let previous = vault.drafts[key]
        let draft = RouteSavedDraft(record: record, base: base, revision: UUID(), queued: false)
        vault.drafts[key] = draft; self.revision &+= 1
        do { try await persist(context); return draft }
        catch {
            if boundContext == context, vault.drafts[key] == draft { vault.drafts[key] = previous; self.revision &+= 1 }
            throw error
        }
    }
    public func discardLocal(_ key: RouteDayKey, revision: UUID?) async throws {
        let (context, _) = try capture(); try await hydrate(context); try check(context)
        guard vault.drafts[key.storageKey]?.revision == revision else { throw RouteRepositoryError.localConflict }
        let previous = vault.drafts[key.storageKey]
        vault.drafts[key.storageKey] = nil; self.revision &+= 1
        do { try await persist(context) }
        catch {
            if boundContext == context, vault.drafts[key.storageKey] == nil {
                vault.drafts[key.storageKey] = previous; self.revision &+= 1
            }
            throw error
        }
    }
    public func send(_ record: RouteDayRecord, base: RouteDayRecord?) async throws -> RouteDayRecord {
        let (context, service) = try capture()
        try await hydrate(context); try check(context)
        if let message = RouteDraftController.validationMessage(record) { throw AppServiceError.message(message) }
        let key = record.key
        guard !sending.contains(key) else { throw RouteRepositoryError.busy }
        if let draft = vault.drafts[key.storageKey], draft.record != record { throw RouteRepositoryError.localConflict }
        if vault.drafts[key.storageKey] == nil { _ = try await saveLocal(record, base: base, replacing: nil) }
        try check(context)
        guard !sending.contains(key) else { throw RouteRepositoryError.busy }
        sending.insert(key); remoteGeneration &+= 1
        dayGenerations[key, default: 0] &+= 1
        defer { if boundContext == context { sending.remove(key) } }
        let settings = self.settings
        do {
            let remote = try await service.fetchDay(date: key.date, workType: key.workType, settings: settings)
            try check(context)
            let result: RouteDayRecord
            if RouteFingerprint.matches(remote, record), let remote { result = remote }
            else {
                guard RouteFingerprint.matches(remote, base) else { throw RouteRepositoryError.conflict }
                result = try await service.sendDay(record, date: key.date, settings: settings)
                try check(context)
            }
            var confirmed = result
            // iOS marks the local receipt after success; upstream echoes sent=false from the request.
            confirmed.sent = true
            remoteGeneration &+= 1; dayGenerations[key, default: 0] &+= 1
            vault.remote[key.storageKey] = confirmed
            let previousDraft = vault.drafts[key.storageKey]
            if vault.drafts[key.storageKey]?.record == record { vault.drafts[key.storageKey] = nil }
            loadedKeys.insert(key.storageKey); connections[key.storageKey] = .online; revision &+= 1
            do { try await persist(context) }
            catch {
                if boundContext == context, vault.drafts[key.storageKey] == nil, previousDraft?.record == record {
                    vault.drafts[key.storageKey] = previousDraft; revision &+= 1
                }
                throw error
            }
            return confirmed
        } catch {
            guard boundContext == context, !AppErrorClassification.isCancellation(error) else { throw error }
            handle(error)
            if active, Self.isOffline(error), vault.drafts[key.storageKey]?.record == record {
                vault.drafts[key.storageKey]?.queued = true; connections[key.storageKey] = .offline; revision &+= 1
                try await persist(context)
                throw RouteRepositoryError.queued(error.localizedDescription)
            }
            throw error
        }
    }
    public func loadArchive(force: Bool = false) async throws {
        let (context, service) = try capture(); try await hydrate(context); try check(context)
        if !force, archiveConnection == .online { return }
        if let archiveFlight { _ = try await archiveFlight.value; return }
        let generation = remoteGeneration; let settings = self.settings
        let task = Task { try await service.fetchAllDays(settings: settings) }
        archiveFlight = task; isLoadingArchive = true; archiveError = nil
        defer { if boundContext == context { archiveFlight = nil; isLoadingArchive = false } }
        do {
            let records = try await task.value; try check(context)
            guard generation == remoteGeneration else { throw CancellationError() }
            vault.remote = Dictionary(records.map { ($0.key.storageKey, $0) }, uniquingKeysWith: { _, new in new })
            archiveConnection = .online; revision &+= 1; try await persist(context)
        } catch {
            if boundContext == context, !AppErrorClassification.isCancellation(error) {
                handle(error)
                if active { archiveError = error.localizedDescription; if Self.isOffline(error) { archiveConnection = .offline } }
            }
            throw error
        }
    }
    public func loadOfficeAddresses() async throws {
        let (context, service) = try capture()
        let addresses = try await service.fetchOfficeAddresses(); try check(context); officeAddresses = addresses
    }
    private func handle(_ error: Error) {
        if case RouteDayServiceError.unauthorized = error {
            requiresAuthentication = true; vault = Vault(); loadedKeys = []; connections = [:]
            hydration?.cancel(); persistence?.cancel(); flights.values.forEach { $0.task.cancel() }; archiveFlight?.cancel()
            authFailure()
        }
    }
    private static func isOffline(_ error: Error) -> Bool { (error as? RouteDayServiceError)?.shouldQueue == true }
}
