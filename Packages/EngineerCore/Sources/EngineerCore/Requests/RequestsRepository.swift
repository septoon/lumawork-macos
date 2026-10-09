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
        var archiveStates: [String: ArchiveSyncState]?
        var archiveCheckpoints: [String: ArchiveCheckpoint]?
        var importedPersonal: [String: SimpleOneRequestRecord]?
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
    public private(set) var archiveProgress: [RequestCollection: RequestsArchiveProgress] = [:]
    public private(set) var archiveNotice: String?
    public private(set) var cacheWarning: String?
    private var active: Bool { bound != nil && bound == context() && session()?.user.sysID == bound?.simpleOneUserID }

    public init(session: @escaping () -> SimpleOneSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping () -> any SimpleOneRequestsServing, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        hydration?.cancel(); persistence?.cancel(); timeFlight?.cancel(); flights.values.forEach { $0.cancel() }; detailFlights.values.forEach { $0.cancel() }
        timeFlight = nil; timeFlightID = nil; loadedTime = false; isLoadingTime = false; timeOffline = false; timeError = nil
        archiveProgress = [:]; archiveNotice = nil
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
            if !hydrated {
                vault = result; hydrated = true; hydration = nil
                for collection in [RequestCollection.personal(.closed), .groupClosed] {
                    if let saved = vault.archiveCheckpoints?[collection.key] { archiveProgress[collection] = RequestsArchiveProgress(loaded: saved.metadata.count, total: saved.total, canResume: true) }
                }
            }
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
        if !force, loaded.contains(collection), collection.source != .closed { return }
        if !force, collection.source == .closed, loaded.contains(collection), let date = updatedAt(collection), Date().timeIntervalSince(date) < 60, vault.archiveCheckpoints?[collection.key] == nil { return }
        if let flight = flights[collection] { try await flight.value; try check(captured); return }
        let id = UUID(); flightIDs[collection] = id; loading.insert(collection); errors[collection] = nil
        let api = service()
        let task = Task {
            do {
                let records: [SimpleOneRequestRecord]
                if collection.source == .closed { records = try await self.synchronizeArchive(collection, api: api, credentials: credentials, captured: captured, force: force) }
                else { records = try await api.fetch(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey) }
                try self.check(captured)
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
    private func synchronizeArchive(_ collection: RequestCollection, api: any SimpleOneRequestsServing,
                                    credentials: SimpleOneSession, captured: SessionContext, force: Bool) async throws -> [SimpleOneRequestRecord] {
        let key = collection.key, identity = try api.archiveIdentity(collection: collection, userID: credentials.user.sysID)
        let state = vault.archiveStates?[key]
        let knownIDsByNumber = Dictionary((state?.metadata ?? [:]).map { ($0.value.number, $0.key) }, uniquingKeysWith: { first, _ in first })
        let cachedByNumber = Dictionary((snapshot(collection)?.records ?? []).map { ($0.number, $0) }, uniquingKeysWith: { _, newer in newer })
        let cachedByID = Dictionary((snapshot(collection)?.records ?? []).filter { !$0.sysID.isEmpty }.map { ($0.sysID, $0) }, uniquingKeysWith: { _, newer in newer })
        var pass = vault.archiveCheckpoints?[key]
        if force || pass?.query != identity { pass = nil }
        if let saved = pass, saved.nextPage > 1 {
            let head = try await api.fetchArchivePage(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey, page: 1); try check(captured)
            let previous = try await api.fetchArchivePage(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey, page: saved.nextPage - 1); try check(captured)
            if head.records.map(ArchiveVersion.init) != saved.head || previous.records.map(ArchiveVersion.init) != saved.previousPage || head.total != saved.total { pass = nil }
        }
        if pass == nil {
            let incremental = !force && state?.query == identity && state?.trusted == true && state?.watermark != nil
            pass = ArchiveCheckpoint(query: identity, incremental: incremental)
        }
        var checkpoint = pass!
        if vault.archiveCheckpoints == nil { vault.archiveCheckpoints = [:] }
        vault.archiveCheckpoints?[key] = checkpoint; revision &+= 1
        archiveProgress[collection] = RequestsArchiveProgress(loaded: checkpoint.metadata.count, total: checkpoint.total, canResume: true)
        try await persist(captured); try check(captured)
        do {
            while !checkpoint.reachedBoundary {
                try check(captured)
                let page = try await api.fetchArchivePage(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey, page: checkpoint.nextPage); try check(captured)
                if checkpoint.nextPage == 1 {
                    checkpoint.head = page.records.map(ArchiveVersion.init); checkpoint.total = page.total
                    // Unknown total or changed membership requires a full pass, never a familiar-page stop.
                    if checkpoint.incremental && (page.total == nil || page.total != state?.metadata.count) { checkpoint.incremental = false }
                } else if page.total != checkpoint.total { throw ArchiveSyncError.changed }
                let countBefore = checkpoint.metadata.count
                for var record in page.records {
                    guard checkpoint.metadata[record.sysID] == nil else { throw ArchiveSyncError.incomplete }
                    let cursor = ArchiveCursor(record)
                    if let cursor, let previous = checkpoint.previousCursor, cursor > previous { throw ArchiveSyncError.changed }
                    if let cursor { checkpoint.previousCursor = cursor; if checkpoint.watermark == nil { checkpoint.watermark = cursor } }
                    else { checkpoint.versionsValid = false; checkpoint.incremental = false }
                    if checkpoint.incremental, let watermark = state?.watermark, let cursor, cursor.updatedAt < watermark.updatedAt {
                        checkpoint.reachedBoundary = true; break
                    }
                    let known = state?.metadata[record.sysID]
                    if let version = record.sysUpdatedAt, !version.isEmpty, known?.version == version,
                       let cached = cachedByID[record.sysID], cached.sysUpdatedAt == version, known?.excluded == false {
                        record = cached
                    } else if record.merchantTIN.isEmpty || cursor == nil {
                        let detailed = try await api.detail(record: record, authKey: credentials.authKey); try check(captured)
                        guard detailed.sysID == record.sysID else { throw ArchiveSyncError.identity }
                        if let original = record.sysUpdatedAt, !original.isEmpty, detailed.sysUpdatedAt != original { throw ArchiveSyncError.changed }
                        record = detailed
                    }
                    if record.merchantTIN.isEmpty, let previousTIN = cachedByNumber[record.number]?.merchantTIN, !previousTIN.isEmpty {
                        record.tableFields = (record.tableFields ?? []) + [ClosedRequestInfoField(key: "ИНН ТСП", value: previousTIN)]
                    }
                    let included = collection != .personal(.closed) || RequestsPolicy.includedInArchive(record)
                    checkpoint.metadata[record.sysID] = ArchiveMetadata(number: record.number, version: record.sysUpdatedAt ?? "", excluded: !included)
                    if included { checkpoint.records[record.sysID] = record }
                }
                if page.hasMore && !checkpoint.reachedBoundary && checkpoint.metadata.count == countBefore { throw ArchiveSyncError.incomplete }
                checkpoint.previousPage = page.records.map(ArchiveVersion.init)
                checkpoint.nextPage += 1
                if !page.hasMore { checkpoint.reachedBoundary = true }
                if vault.archiveCheckpoints == nil { vault.archiveCheckpoints = [:] }
                vault.archiveCheckpoints?[key] = checkpoint; revision &+= 1
                archiveProgress[collection] = RequestsArchiveProgress(loaded: checkpoint.metadata.count, total: checkpoint.total, canResume: true)
                // A continuation is durable only after the encrypted checkpoint has been written.
                try await persist(captured); try check(captured)
            }
            let head = try await api.fetchArchivePage(collection: collection, userID: credentials.user.sysID, authKey: credentials.authKey, page: 1); try check(captured)
            guard head.records.map(ArchiveVersion.init) == checkpoint.head, head.total == checkpoint.total else { throw ArchiveSyncError.changed }
            var metadata = checkpoint.incremental ? state?.metadata ?? [:] : [:]
            var records = checkpoint.incremental ? Dictionary((snapshot(collection)?.records ?? []).filter { !$0.sysID.isEmpty }.map { ($0.sysID, $0) }, uniquingKeysWith: { _, newer in newer }) : [:]
            for (id, item) in checkpoint.metadata {
                metadata[id] = item
                if item.excluded { records[id] = nil } else { records[id] = checkpoint.records[id] }
            }
            guard checkpoint.total.map({ metadata.count == $0 }) ?? true else { throw ArchiveSyncError.incomplete }
            var numbers: [String: String] = [:]
            for (id, item) in metadata {
                if let existing = numbers[item.number], existing != id { throw ArchiveSyncError.identity }
                numbers[item.number] = id
            }
            if collection == .personal(.closed) {
                // Personal history is accumulated by request number, as in the source store.
                // Only the group archive reconciles deletions against the current server set.
                var history = cachedByNumber
                for record in checkpoint.records.values {
                    if state?.query == identity {
                        guard state?.metadata[record.sysID].map({ $0.number == record.number }) ?? true,
                              knownIDsByNumber[record.number].map({ $0 == record.sysID }) ?? true else { throw ArchiveSyncError.identity }
                    }
                    history[record.number] = record
                }
                for imported in vault.importedPersonal?.values ?? Dictionary<String, SimpleOneRequestRecord>().values where history[imported.number] == nil && numbers[imported.number] == nil {
                    history[imported.number] = imported
                }
                guard Set(history.values.map(\.id)).count == history.count else { throw ArchiveSyncError.identity }
                records = history
            }
            if vault.archiveStates == nil { vault.archiveStates = [:] }
            vault.archiveStates?[key] = ArchiveSyncState(query: identity, watermark: checkpoint.watermark, metadata: metadata, trusted: checkpoint.versionsValid)
            vault.archiveCheckpoints?[key] = nil
            archiveProgress[collection] = nil
            return Array(records.values)
        } catch {
            if error is ArchiveSyncError {
                vault.archiveCheckpoints?[key] = nil; revision &+= 1; archiveProgress[collection] = nil
                try? await persist(captured)
                try check(captured)
                if checkpoint.incremental { return try await synchronizeArchive(collection, api: api, credentials: credentials, captured: captured, force: true) }
            }
            throw error
        }
    }
    public func importArchive(_ preview: ArchiveImportPreview, expectedContext: SessionContext) async throws {
        let (captured, _) = try capture()
        guard captured == expectedContext else { throw CancellationError() }
        try await prepare(); try check(captured)
        let collection = RequestCollection.personal(.closed)
        flights[collection]?.cancel(); flights[collection] = nil; flightIDs[collection] = nil; loading.remove(collection)
        var byNumber = Dictionary(records(collection).map { ($0.number, $0) }, uniquingKeysWith: { _, last in last })
        var imports = vault.importedPersonal ?? [:], added = 0, updated = 0
        for incoming in preview.records {
            var record = incoming
            if let current = byNumber[record.number] {
                if record.sysID.isEmpty { record.sysID = current.sysID }
                updated += current == record ? 0 : 1
            } else { added += 1 }
            byNumber[record.number] = record; imports[record.number] = record
        }
        guard Set(byNumber.values.map(\.id)).count == byNumber.count else { throw ArchiveSyncError.identity }
        vault.lists[.closed] = Snapshot(records: Array(byNumber.values), updatedAt: Date())
        vault.importedPersonal = imports; vault.archiveStates?[collection.key] = nil; vault.archiveCheckpoints?[collection.key] = nil
        let importedNumbers = Set(preview.records.map(\.number))
        vault.details = vault.details.filter { !importedNumbers.contains($0.value.record.number) }
        archiveProgress[collection] = nil; loaded.remove(collection); revision &+= 1
        do { try await persist(captured); try check(captured) }
        catch { try check(captured); cacheWarning = "Архив импортирован в память, но кеш не сохранён: " + error.localizedDescription }
        archiveNotice = "Импорт: +\(added) новых, \(updated) обновлено, всего \(byNumber.count). Дубли в файле: \(preview.duplicateCount); использована последняя строка."
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
