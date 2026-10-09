import Foundation
import Observation

@MainActor @Observable
public final class FeedbackRepository {
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: (AppSession) -> FeedbackAPI
    private let authFailure: () -> Void
    private let report: (String) -> Void
    private var bound: SessionContext?
    private var hydrated = false
    private var loaded = false
    private var cacheWrite: Task<Void, Error>?
    private var outboxWrite: Task<Void, Error>?
    private var indexLoad: Task<[FeedbackDraftReference], Error>?
    private var indexHydrated = false
    private var references: [FeedbackDraftReference] = []
    private var claimedSlots: Set<UUID> = []
    public var availableDrafts: [FeedbackDraftReference] { references.filter { !claimedSlots.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt } }
    public private(set) var messages: [FeedbackMessage] = []
    public private(set) var isLoading = false
    public private(set) var busySlots: Set<UUID> = []
    public private(set) var progress: [UUID: Double] = [:]
    public private(set) var error: String?
    public private(set) var uncertainAdditions: Set<String> = []
    private var adding: Set<String> = []
    private var mutationRevision = 0
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> FeedbackAPI, authFailure: @escaping () -> Void, report: @escaping (String) -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.authFailure = authFailure; self.report = report
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        cacheWrite?.cancel(); cacheWrite = nil; outboxWrite?.cancel(); outboxWrite = nil; indexLoad?.cancel(); indexLoad = nil; indexHydrated = false; references = []; claimedSlots = []
        bound = context(); hydrated = false; loaded = false; messages = []; isLoading = false
        busySlots = []; progress = [:]; error = nil; uncertainAdditions = []; adding = []; mutationRevision = 0
    }
    private func capture() throws -> (SessionContext, FeedbackAPI) {
        synchronizeSession()
        guard let captured = bound, let session = session(), session.user.id == captured.userID else { throw CancellationError() }
        try check(captured); return (captured, service(session))
    }
    private func check(_ captured: SessionContext) throws {
        try Task.checkCancellation(); guard context() == captured, bound == captured else { throw CancellationError() }
    }
    private func failed(_ error: Error, captured: SessionContext) {
        guard context() == captured, bound == captured, !AppErrorClassification.isCancellation(error) else { return }
        self.error = error.localizedDescription; report(error.localizedDescription)
        if DomainHTTPClient.isUnauthorized(error) { messages = []; authFailure() }
    }
    private func persistMessages(_ captured: SessionContext) async throws {
        let data = try JSONEncoder().encode(messages), store = try storage(), scope = try SnapshotScope(userID: captured.userID), previous = cacheWrite
        let task = Task { if let previous { _ = try? await previous.value }; try check(captured); try await store.save(data, key: "feedback-messages.v1", scope: scope) }
        cacheWrite = task; try await task.value; try check(captured)
    }
    public func load(force: Bool = false) async throws {
        let (captured, api) = try capture(); guard !isLoading else { return }
        guard adding.isEmpty, busySlots.isEmpty else { throw AppServiceError.message("Дождитесь завершения отправки сообщения или дополнения.") }
        let revision = mutationRevision, previousUncertainty = uncertainAdditions
        isLoading = true
        defer { if bound == captured { isLoading = false } }
        do {
            if !hydrated {
                let data = try await storage().load(key: "feedback-messages.v1", scope: SnapshotScope(userID: captured.userID)); try check(captured)
                guard revision == mutationRevision else { throw CancellationError() }; messages = try data.map { try JSONDecoder().decode([FeedbackMessage].self, from: $0) } ?? []; hydrated = true
            }
            guard !loaded || force else { return }
            let value = try await api.messages(); try check(captured)
            guard revision == mutationRevision, adding.isEmpty, busySlots.isEmpty else { throw CancellationError() }
            messages = value; loaded = true; error = nil
            // Refresh reconciles non-idempotent additions before an explicit retry.
            uncertainAdditions.subtract(previousUncertainty); try await persistMessages(captured)
        } catch { failed(error, captured: captured); throw error }
    }
    public func pending(slot: UUID) async throws -> FeedbackPending? {
        let (captured, _) = try capture()
        if let writing = outboxWrite { try await writing.value; try check(captured) }
        let data = try await storage().load(key: "feedback-draft.v1." + slot.uuidString, scope: SnapshotScope(userID: captured.userID)); try check(captured)
        return try data.map { try JSONDecoder().decode(FeedbackPending.self, from: $0) }
    }
    public func loadDraftIndex() async throws {
        let (captured, _) = try capture(); guard !indexHydrated else { return }
        let task: Task<[FeedbackDraftReference], Error>
        if let indexLoad { task = indexLoad }
        else {
            let store = try storage(), scope = try SnapshotScope(userID: captured.userID)
            task = Task { let data = try await store.load(key: "feedback-draft-index.v1", scope: scope); try self.check(captured); return try data.map { try JSONDecoder().decode([FeedbackDraftReference].self, from: $0) } ?? [] }
            indexLoad = task
        }
        do { let value = try await task.value; try check(captured); if !indexHydrated { references = value; indexHydrated = true }; indexLoad = nil }
        catch { if bound == captured { indexLoad = nil }; throw error }
    }
    public func claim(_ slot: UUID) throws {
        _ = try capture(); guard !claimedSlots.contains(slot) else { throw AppServiceError.message("Этот черновик открыт в другом окне.") }; claimedSlots.insert(slot)
    }
    public func release(_ slot: UUID) { claimedSlots.remove(slot) }
    public func save(_ pending: FeedbackPending?, slot: UUID, expectedContext: SessionContext) async throws {
        let (captured, _) = try capture(); guard captured == expectedContext else { throw CancellationError() }
        let value = pending ?? FeedbackPending(), data = try JSONEncoder().encode(value), store = try storage(), scope = try SnapshotScope(userID: captured.userID), previous = outboxWrite
        let task = Task {
            if let previous { _ = try? await previous.value }; try check(captured)
            try await loadDraftIndex(); try check(captured)
            if value.hasContent {
                references.removeAll { $0.id == slot }
                references.append(FeedbackDraftReference(id: slot, title: value.draft.title, attempted: value.attempted, updatedAt: Date()))
                // Register first: a crash must never leave an undiscoverable attempted payload.
                try await store.save(JSONEncoder().encode(references), key: "feedback-draft-index.v1", scope: scope); try check(captured)
                try await store.save(data, key: "feedback-draft.v1." + slot.uuidString, scope: scope)
            } else {
                try await store.save(data, key: "feedback-draft.v1." + slot.uuidString, scope: scope); try check(captured)
                references.removeAll { $0.id == slot }
                try await store.save(JSONEncoder().encode(references), key: "feedback-draft-index.v1", scope: scope)
            }
            try check(captured)
        }
        outboxWrite = task; try await task.value; try check(captured)
    }
    public func submit(_ pending: FeedbackPending, slot: UUID, device: FeedbackDeviceInfo, expectedContext: SessionContext) async throws -> FeedbackMessage {
        let (captured, api) = try capture(); guard captured == expectedContext, !busySlots.contains(slot) else { throw CancellationError() }
        guard pending.images.count <= 4, pending.images.reduce(0, { $0 + $1.data.count }) <= 10 * 1024 * 1024 else { throw AppServiceError.message("Можно прикрепить до четырёх снимков общим размером до 10 МБ.") }
        busySlots.insert(slot); mutationRevision &+= 1; progress[slot] = 0
        defer { if bound == captured { busySlots.remove(slot); mutationRevision &+= 1; progress[slot] = nil } }
        do {
            var stored = pending; stored.attempted = true; stored.device = stored.device ?? device
            try await save(stored, slot: slot, expectedContext: captured); try check(captured)
            let draft = try await api.createDraft(stored.draft, device: stored.device!); try check(captured)
            let submitted: FeedbackMessage
            if draft.status == .draft {
                for (index, image) in stored.images.enumerated() {
                    try await api.upload(image, reportID: draft.id, check: { try self.check(captured) }, progress: {
                        self.progress[slot] = (Double(index) + $0) / Double(max(1, stored.images.count))
                    }); try check(captured)
                }
                submitted = try await api.submit(id: draft.id); try check(captured)
                guard submitted.id == draft.id, submitted.status != .draft else { throw GsmFuelError.invalidResponse }
            } else { submitted = draft } // Lost submit response: the server has already accepted this ID.
            replace(submitted); try await persistMessages(captured)
            try await save(nil, slot: slot, expectedContext: captured)
            report("Сообщение \(submitted.number) отправлено."); return submitted
        } catch { failed(error, captured: captured); throw error }
    }
    public func add(_ text: String, id: String, expectedContext: SessionContext) async throws {
        let (captured, api) = try capture(); guard captured == expectedContext, !adding.contains(id) else { throw CancellationError() }
        guard !uncertainAdditions.contains(id) else { throw AppServiceError.message("Результат дополнения неизвестен. Обновите сообщение и проверьте дополнения перед повтором.") }
        adding.insert(id); mutationRevision &+= 1; defer { if bound == captured { adding.remove(id); mutationRevision &+= 1 } }
        do {
            let updated = try await api.add(text: text, id: id); try check(captured)
            guard updated.id == id else { throw GsmFuelError.invalidResponse }
            replace(updated); try await persistMessages(captured); report("Дополнение отправлено.")
        } catch {
            if context() == captured, bound == captured, DomainHTTPClient.isUncertain(error) { uncertainAdditions.insert(id) }
            failed(error, captured: captured); throw error
        }
    }
    public func attachment(reportID: String, attachmentID: String) async throws -> URL {
        let (captured, api) = try capture(), file = try await api.attachment(reportID: reportID, attachmentID: attachmentID)
        do { try check(captured); return file } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private func replace(_ message: FeedbackMessage) {
        messages.removeAll { $0.id == message.id }; messages.append(message)
        messages.sort { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
    }
}
