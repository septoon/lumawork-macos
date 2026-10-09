import Foundation
import Observation

// A shared cache/read lifecycle for the independent read-only SimpleOne domains.
// Selection, queries and drafts are owned by windows; keys include each query's identity.
@MainActor @Observable
public final class SimpleOneResourceRepository<Value: Codable & Sendable> {
    private let session: () -> SimpleOneSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let namespace: String
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var values: [String: Value] = [:]
    private var hydrated: Set<String> = []
    private var loaded: Set<String> = []
    private var flights: [String: Task<Void, Error>] = [:]
    private var hydration: [String: Task<Void, Error>] = [:]
    private var persistence: [String: Task<Void, Error>] = [:]
    private var revisions: [String: Int] = [:]
    public private(set) var errors: [String: String] = [:]
    public private(set) var offline: Set<String> = []
    public private(set) var cacheWarning: String?
    public init(namespace: String, session: @escaping () -> SimpleOneSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, authFailure: @escaping () -> Void) {
        self.namespace = namespace; self.session = session; self.context = context; self.storage = storage; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        flights.values.forEach { $0.cancel() }; hydration.values.forEach { $0.cancel() }; persistence.values.forEach { $0.cancel() }
        bound = context(); values = [:]; hydrated = []; loaded = []; flights = [:]; hydration = [:]; persistence = [:]; revisions = [:]; errors = [:]; offline = []; cacheWarning = nil
    }
    public func value(_ key: String) -> Value? { bound == context() && bound?.simpleOneUserID != nil ? values[key] : nil }
    public func isLoading(_ key: String) -> Bool { flights[key] != nil || hydration[key] != nil }
    private func check(_ captured: SessionContext) throws {
        try Task.checkCancellation(); guard bound == captured, context() == captured, captured.simpleOneUserID == session()?.user.sysID else { throw CancellationError() }
    }
    private func capture() throws -> (SessionContext, SimpleOneSession) {
        synchronizeSession(); guard let captured = bound, let session = session(), !session.authKey.isEmpty, captured.simpleOneUserID == session.user.sysID else { throw SimpleOneServiceError.missingCredentials }
        try check(captured); return (captured, session)
    }
    private func hydrate(_ key: String, captured: SessionContext) async throws {
        if hydrated.contains(key) { return }
        if let task = hydration[key] { try await task.value; try check(captured); return }
        let vault = try storage(), scope = try SnapshotScope(userID: captured.userID, simpleOneUserID: captured.simpleOneUserID)
        let task = Task {
            do {
                let data = try await vault.load(key: self.namespace + "." + key, scope: scope); try self.check(captured)
                if let data { self.values[key] = try JSONDecoder().decode(Value.self, from: data) }
            } catch { try self.check(captured); self.cacheWarning = "Локальный кеш недоступен." }
            self.hydrated.insert(key)
        }; hydration[key] = task
        defer { if bound == captured { hydration[key] = nil } }
        try await task.value; try check(captured)
    }
    private func persist(_ key: String, captured: SessionContext) async throws {
        try check(captured); revisions[key, default: 0] += 1
        do {
            let task: Task<Void, Error>
            if let pending = persistence[key] { task = pending }
            else {
                let vault = try storage(), scope = try SnapshotScope(userID: captured.userID, simpleOneUserID: captured.simpleOneUserID)
                task = Task {
                    repeat {
                        try self.check(captured); let version = self.revisions[key]
                        let data = try JSONEncoder().encode(self.values[key])
                        try await vault.save(data, key: self.namespace + "." + key, scope: scope); try self.check(captured)
                        if version == self.revisions[key] { break }
                    } while true
                }; persistence[key] = task
            }
            do { try await task.value; try check(captured); persistence[key] = nil; cacheWarning = nil }
            catch { if bound == captured { persistence[key] = nil }; throw error }
        } catch { try check(captured); cacheWarning = "Данные получены, но локальный кеш не сохранён." }
    }
    public func load(_ key: String, force: Bool = false, fetch: @escaping (SimpleOneSession) async throws -> Value) async throws {
        let (captured, session) = try capture(); try await hydrate(key, captured: captured); try check(captured)
        if let task = flights[key] { try await task.value; try check(captured); return }
        if loaded.contains(key), !force { return }
        let task = Task {
            do {
                let result = try await fetch(session); try self.check(captured)
                self.values[key] = result; self.loaded.insert(key); self.offline.remove(key); self.errors[key] = nil
                try await self.persist(key, captured: captured)
            } catch {
                try self.check(captured); self.errors[key] = error.localizedDescription
                if case .network = AppErrorClassification.classification(for: error) { self.offline.insert(key) }
                if case SimpleOneServiceError.unauthorized = error { self.authFailure() }
                if case SimpleOneServiceError.forbidden = error { self.authFailure() }
                throw error
            }
        }; flights[key] = task
        defer { if bound == captured { flights[key] = nil } }
        try await task.value; try check(captured)
    }
    public func loadLocal(_ key: String) async throws { let (captured, _) = try capture(); try await hydrate(key, captured: captured); try check(captured) }
    public func setLocal(_ value: Value, key: String, expectedContext: SessionContext) async throws {
        let (captured, _) = try capture(); guard captured == expectedContext else { throw CancellationError() }
        try await hydrate(key, captured: captured); try check(captured)
        values[key] = value; try await persist(key, captured: captured)
    }
}
public struct EmployeeDirectory: Codable, Sendable {
    public let employees: [SimpleOneEmployee]
    public let totalCount: Int
    public init(employees: [SimpleOneEmployee], totalCount: Int) { self.employees = employees; self.totalCount = totalCount }
}
