import Foundation
import Observation

@MainActor @Observable public final class WikiRepository {
    private struct Vault: Codable {
        var searches: [String: WikiSearchPage] = [:]
        var articles: [String: WikiArticle] = [:]
        var health: WikiHealthResponse?
        var catalogVersion: String?
    }
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: () throws -> WikiAPI
    private let namespace: String
    private let report: (String) -> Void
    private var bound: SessionContext?
    private var generation = UUID()
    private var vault = Vault()
    private var hydration: Task<Void, Error>?
    private var hydrated = false
    private var persistence: Task<Void, Error>?
    private var revision = 0
    private var flights: [String: Task<Void, Error>] = [:]
    private var loaded: Set<String> = []
    private var flightTokens: [String: UUID] = [:]
    public private(set) var authorizationRequired = false
    public private(set) var cacheWarning: String?
    public init(namespace: String, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping () throws -> WikiAPI, report: @escaping (String) -> Void) { self.namespace = namespace; self.context = context; self.storage = storage; self.service = service; self.report = report }
    private var active: Bool { bound != nil && bound == context() }
    public func search(_ query: String) -> WikiSearchPage? { active ? vault.searches[query.trimmingCharacters(in: .whitespacesAndNewlines)] : nil }
    public func article(_ id: String) -> WikiArticle? { active ? vault.articles[id] : nil }
    public var catalogVersion: String? { active ? vault.catalogVersion : nil }
    public var health: WikiHealthResponse? { active ? vault.health : nil }
    public func isLoading(_ key: String) -> Bool { flights[key] != nil || hydration != nil }
    public func synchronizeSession(force: Bool = false) {
        guard force || bound != context() else { return }
        hydration?.cancel(); persistence?.cancel(); flights.values.forEach { $0.cancel() }
        bound = context(); generation = UUID(); vault = .init(); hydrated = false; hydration = nil; persistence = nil; flights = [:]; flightTokens = [:]; loaded = []; revision = 0; authorizationRequired = false; cacheWarning = nil
    }
    private func check(_ captured: SessionContext, generation: UUID) throws { try Task.checkCancellation(); guard active, bound == captured, self.generation == generation else { throw CancellationError() } }
    private func hydrate(_ captured: SessionContext, generation: UUID) async throws {
        if hydrated { return }
        if let hydration { try await hydration.value; try check(captured, generation: generation); return }
        let store = try storage(), scope = try SnapshotScope(userID: captured.userID)
        let task = Task {
            do { let data = try await store.load(key: self.namespace, scope: scope); try self.check(captured, generation: generation); if let data { self.vault = try JSONDecoder().decode(Vault.self, from: data) } }
            catch { try self.check(captured, generation: generation); self.cacheWarning = "Локальный кеш Wiki недоступен." }
            self.hydrated = true
        }; hydration = task
        defer { if self.generation == generation { hydration = nil } }
        try await task.value; try check(captured, generation: generation)
    }
    private func persist(_ captured: SessionContext, generation: UUID) async throws {
        try check(captured, generation: generation); revision += 1
        let task: Task<Void, Error>
        if let persistence { task = persistence }
        else {
            let store = try storage(), scope = try SnapshotScope(userID: captured.userID)
            task = Task {
                repeat {
                    try self.check(captured, generation: generation); let version = self.revision
                    try await store.save(JSONEncoder().encode(self.vault), key: self.namespace, scope: scope); try self.check(captured, generation: generation)
                    if version == self.revision { break }
                } while true
            }; persistence = task
        }
        do { try await task.value; try check(captured, generation: generation); persistence = nil; cacheWarning = nil }
        catch { try check(captured, generation: generation); persistence = nil; cacheWarning = "Кеш Wiki не сохранён на Mac." }
    }
    private func load(_ name: String, force: Bool, action: @escaping (WikiAPI) async throws -> Void) async throws {
        synchronizeSession(); guard let captured = bound else { throw CancellationError() }; let generation = self.generation
        try await hydrate(captured, generation: generation); try check(captured, generation: generation)
        if let task = flights[name] { try await task.value; try check(captured, generation: generation); return }
        if loaded.contains(name), !force { return }
        let api = try service(), token = UUID()
        let task = Task {
            do { try await action(api); try self.check(captured, generation: generation); self.loaded.insert(name); if name != "health" { self.authorizationRequired = false }; try await self.persist(captured, generation: generation) }
            catch { try self.check(captured, generation: generation); if AppErrorClassification.isCancellation(error) { throw error }; if DomainHTTPClient.isUnauthorized(error) { self.authorizationRequired = true }; self.report(error.localizedDescription); throw error }
        }; flights[name] = task; flightTokens[name] = token
        defer { if self.generation == generation, flightTokens[name] == token { flights[name] = nil; flightTokens[name] = nil } }
        try await task.value; try check(captured, generation: generation)
    }
    public func loadSearch(_ raw: String, force: Bool = false) async throws {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !query.isEmpty else { return }
        synchronizeSession()
        let generation = self.generation, captured = context()
        try await load("search:" + query, force: force) { api in
            let baseline = self.vault.catalogVersion
            let page = try await api.search(query: query); guard self.generation == generation, self.context() == captured else { throw CancellationError() }
            try self.acceptVersion(page.snapshotID, baseline: baseline, excluding: "search:" + query)
            self.vault.searches[query] = page
            if self.vault.searches.count > 40, let old = self.vault.searches.keys.first(where: { $0 != query }) { self.vault.searches[old] = nil; self.loaded.remove("search:" + old) }
        }
    }
    public func loadArticle(_ id: String, force: Bool = false) async throws {
        synchronizeSession()
        let generation = self.generation, captured = context()
        try await load("article:" + id, force: force) { api in
            let baseline = self.vault.catalogVersion
            let value = try await api.article(id: id); guard self.generation == generation, self.context() == captured else { throw CancellationError() }; try self.acceptVersion(value.snapshotId, baseline: baseline, excluding: "article:" + id); self.vault.articles[id] = value
            if self.vault.articles.count > 40, let old = self.vault.articles.keys.first(where: { $0 != id }) { self.vault.articles[old] = nil; self.loaded.remove("article:" + old) }
        }
    }
    public func loadHealth(force: Bool = false) async throws {
        synchronizeSession()
        let generation = self.generation, captured = context()
        try await load("health", force: force) { api in
            let baseline = self.vault.catalogVersion
            let value = try await api.health(); guard self.generation == generation, self.context() == captured else { throw CancellationError() }
            try self.acceptVersion(value.snapshotId ?? value.contentVersion, baseline: baseline, excluding: "health")
            self.vault.health = value
        }
    }
    private func acceptVersion(_ version: String?, baseline: String?, excluding current: String) throws {
        try Task.checkCancellation()
        // A response started against an older catalog cannot roll the shared cache back.
        if vault.catalogVersion != baseline, version != vault.catalogVersion { throw CancellationError() }
        guard let version, version != vault.catalogVersion else { return }
        vault.catalogVersion = version
        for name in Array(flights.keys) where name != current && (name.hasPrefix("article:") || name.hasPrefix("search:")) { flights[name]?.cancel(); flights[name] = nil; flightTokens[name] = nil }
        loaded = loaded.filter { !$0.hasPrefix("article:") && !$0.hasPrefix("search:") }
    }

    public func downloadPDF(_ id: String) async throws -> URL {
        synchronizeSession(); guard let captured = bound else { throw CancellationError() }; let generation = self.generation
        let file = try await service().downloadPDF(id: id)
        do { try check(captured, generation: generation); return file } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}
