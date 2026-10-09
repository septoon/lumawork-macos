import Foundation
import Observation

@MainActor @Observable
public final class AssistantRepository {
    private struct Pending: Codable {
        let requestID: UUID
        let conversationID: UUID
        let message: String
        let image: AssistantPreparedImagePayload?
        let document: AssistantPreparedDocumentPayload?
        var toolResults: [AssistantAPIToolResult]?
        var cycle = 0
    }
    private struct Vault: Codable {
        var conversations: [AssistantAPIConversation] = []
        var messages: [String: [AssistantAPIMessage]] = [:]
        var pending: [String: Pending] = [:]
        var feedbackIDs: [String: UUID] = [:]
    }
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: (AppSession) -> AssistantAPI
    private let executeTools: ([AssistantAPIToolRequest], SessionContext) async throws -> [AssistantAPIToolResult]
    private let authFailure: () -> Void
    private let report: (String) -> Void
    private var bound: SessionContext?
    private var vault = Vault()
    private var hydrated = false
    private var hydration: Task<Void, Error>?
    private var persistence: Task<Void, Error>?
    private var revision = 0
    private var reads: [String: Task<Void, Error>] = [:]
    private var loaded: Set<String> = []
    private var jobs: [String: Task<Void, Never>] = [:]
    private var jobTokens: [String: UUID] = [:]
    private var messageCursors: [String: String] = [:]
    private var mutations: Set<String> = []
    private var conversationRevisions: [String: UUID] = [:]
    private var deletedConversations: Set<UUID> = []
    public private(set) var nextCursor: String?
    public private(set) var activity: [String: String] = [:]
    public private(set) var cacheWarning: String?
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> AssistantAPI, executeTools: @escaping ([AssistantAPIToolRequest], SessionContext) async throws -> [AssistantAPIToolResult], authFailure: @escaping () -> Void, report: @escaping (String) -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.executeTools = executeTools; self.authFailure = authFailure; self.report = report
    }
    private var active: Bool { bound != nil && bound == context() && session()?.user.id == bound?.userID }
    public var conversations: [AssistantAPIConversation] { active ? vault.conversations : [] }
    public func messages(_ id: UUID) -> [AssistantAPIMessage] { active ? vault.messages[key(id)] ?? [] : [] }
    public func isDeleted(_ id: UUID) -> Bool { active && deletedConversations.contains(id) }
    public func isSending(_ id: UUID) -> Bool { active && jobs[key(id)] != nil }
    public func canRetry(_ id: UUID) -> Bool { active && vault.pending[key(id)] != nil && !isSending(id) }
    public func hasOlderMessages(_ id: UUID) -> Bool { active && messageCursors[key(id)] != nil }
    public func isLoading(_ id: UUID? = nil) -> Bool { reads[id.map { "messages:" + key($0) } ?? "history"] != nil || hydration != nil }
    public func isMutating(_ id: UUID) -> Bool { mutations.contains(key(id)) }
    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    public func synchronizeSession() {
        guard bound != context() else { return }
        hydration?.cancel(); persistence?.cancel(); reads.values.forEach { $0.cancel() }; jobs.values.forEach { $0.cancel() }
        bound = context(); vault = .init(); hydrated = false; hydration = nil; persistence = nil; revision = 0; reads = [:]; loaded = []; jobs = [:]; jobTokens = [:]; messageCursors = [:]; mutations = []; conversationRevisions = [:]; deletedConversations = []; nextCursor = nil; activity = [:]; cacheWarning = nil
    }
    private func check(_ captured: SessionContext) throws { try Task.checkCancellation(); guard active, bound == captured else { throw CancellationError() } }
    private func capture() throws -> (SessionContext, AssistantAPI) {
        synchronizeSession(); guard let captured = bound, let session = session(), active else { throw GsmFuelError.staleSession }
        try check(captured); return (captured, service(session))
    }
    private func hydrate(_ captured: SessionContext) async throws {
        if hydrated { return }
        if let task = hydration { try await task.value; try check(captured); return }
        let store = try storage(), scope = try SnapshotScope(userID: captured.userID)
        let task = Task {
            do {
                let data = try await store.load(key: "assistant.v1", scope: scope); try self.check(captured)
                if let data { self.vault = try JSONDecoder().decode(Vault.self, from: data) }
            } catch { try self.check(captured); self.cacheWarning = "Локальная история недоступна." }
            self.hydrated = true
        }; hydration = task
        defer { if bound == captured { hydration = nil } }
        try await task.value; try check(captured)
    }
    private func persist(_ captured: SessionContext) async throws {
        try check(captured); revision += 1
        let task: Task<Void, Error>
        if let persistence { task = persistence }
        else {
            let store = try storage(), scope = try SnapshotScope(userID: captured.userID)
            task = Task {
                repeat {
                    try self.check(captured); let version = self.revision
                    var saved = self.vault
                    saved.conversations = Array(saved.conversations.prefix(100))
                    saved.messages = saved.messages.mapValues { Array($0.suffix(100)) }
                    let retained = Set(saved.conversations.map { self.key($0.id) }).union(saved.pending.keys)
                    saved.messages = saved.messages.filter { retained.contains($0.key) }
                    let retainedMessages = Set(saved.messages.values.flatMap { $0.map { "feedback:" + $0.id + "|" } })
                    saved.feedbackIDs = saved.feedbackIDs.filter { key, _ in retainedMessages.contains(where: { key.hasPrefix($0) }) }
                    try await store.save(JSONEncoder().encode(saved), key: "assistant.v1", scope: scope); try self.check(captured)
                    if version == self.revision { break }
                } while true
            }; persistence = task
        }
        do { try await task.value; try check(captured); persistence = nil; cacheWarning = nil }
        catch { if bound == captured, context() == captured { persistence = nil; cacheWarning = "История не сохранена на Mac." }; throw error }
    }
    private func read(_ name: String, captured: SessionContext, action: @escaping () async throws -> Void) async throws {
        if let task = reads[name] { try await task.value; try check(captured); return }
        let task = Task { try await action(); try self.check(captured); self.loaded.insert(name); try await self.persist(captured) }
        reads[name] = task; defer { if bound == captured { reads[name] = nil } }
        do { try await task.value; try check(captured) } catch { try check(captured); handle(error, captured); throw error }
    }
    public func loadConversations(force: Bool = false, more: Bool = false) async throws {
        let (captured, api) = try capture(); try await hydrate(captured)
        if !force, !more, loaded.contains("history") { return }
        let cursor = more ? nextCursor : nil
        if more, cursor == nil { return }
        try await read("history", captured: captured) {
            let revisions = self.conversationRevisions
            let page = try await api.conversations(cursor: cursor); try self.check(captured)
            let local = self.vault.conversations.filter { self.vault.pending[self.key($0.id)] != nil || self.jobs[self.key($0.id)] != nil || self.mutations.contains(self.key($0.id)) || self.conversationRevisions[self.key($0.id)] != revisions[self.key($0.id)] }
            let base = more ? self.vault.conversations : local
            var result = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in page.conversations where !self.deletedConversations.contains(value.id) && self.jobs[self.key(value.id)] == nil && !self.mutations.contains(self.key(value.id)) && self.conversationRevisions[self.key(value.id)] == revisions[self.key(value.id)] { result[value.id] = value }
            result = result.filter { !self.deletedConversations.contains($0.key) }
            self.vault.conversations = result.values.sorted { $0.lastMessageAt > $1.lastMessageAt }; self.nextCursor = page.nextCursor
        }
    }
    public func loadMessages(_ id: UUID, force: Bool = false, more: Bool = false) async throws {
        let (captured, api) = try capture(); try await hydrate(captured); let name = "messages:" + key(id)
        guard !isSending(id), vault.conversations.contains(where: { $0.id == id }) else { return }
        if !force, !more, loaded.contains(name) { return }
        let cursor = more ? messageCursors[key(id)] : nil
        if more, cursor == nil { return }
        try await read(name, captured: captured) {
            let revision = self.conversationRevisions[self.key(id)]
            let page = try await api.messages(conversationID: id, cursor: cursor); try self.check(captured)
            guard !self.isSending(id), !self.mutations.contains(self.key(id)), !self.deletedConversations.contains(id), self.conversationRevisions[self.key(id)] == revision, self.vault.conversations.contains(where: { $0.id == id }) else { throw CancellationError() }
            self.mergeMessages(page.messages, id: id); self.applyStatus(page.conversation, id: id)
            self.messageCursors[self.key(id)] = page.nextCursor
        }
    }
    private func mergeMessages(_ incoming: [AssistantAPIMessage], id: UUID) {
        func identity(_ value: AssistantAPIMessage) -> String { value.requestId.map { $0.lowercased() + "|" + value.role } ?? value.id }
        var merged = Dictionary((vault.messages[key(id)] ?? []).map { (identity($0), $0) }, uniquingKeysWith: { _, last in last })
        incoming.forEach { merged[identity($0)] = $0 }
        vault.messages[key(id)] = merged.values.sorted { $0.createdAt == $1.createdAt ? $0.role > $1.role : $0.createdAt < $1.createdAt }
    }
    public func send(message: String, image: AssistantPreparedImagePayload?, document: AssistantPreparedDocumentPayload?, conversationID id: UUID, expectedContext: SessionContext? = nil) async throws {
        let (captured, api) = try capture(); if let expectedContext, expectedContext != captured { throw CancellationError() }; try await hydrate(captured); try check(captured)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines), name = key(id)
        guard !deletedConversations.contains(id) else { throw AppServiceError.message("Чат удалён. Перенесите черновик в новый чат.") }
        guard text.count <= 4000 else { throw AppServiceError.message("Вопрос превышает 4000 символов.") }
        guard !text.isEmpty || image != nil || document != nil else { return }
        guard jobs[name] == nil, vault.pending[name] == nil, !mutations.contains(name) else { throw GsmFuelError.busy }
        guard vault.conversations.first(where: { $0.id == id })?.isFull != true else { throw AppServiceError.message("Лимит чата исчерпан. Создайте новый чат.") }
        mutations.insert(name); defer { if bound == captured { mutations.remove(name) } }
        let pending = Pending(requestID: UUID(), conversationID: id, message: text, image: image, document: document)
        vault.pending[name] = pending
        let display = text.isEmpty ? document.map { "Документ: " + $0.fileName } ?? "Изображение" : text
        let metadata: AssistantJSONValue? = document.map { .object(["kind": .string("document"), "fileName": .string($0.fileName), "mimeType": .string($0.mimeType), "wasTruncated": .bool($0.wasTruncated)]) } ?? (image == nil ? nil : .object(["kind": .string("image")]))
        mergeMessages([AssistantAPIMessage(id: "local-user-" + pending.requestID.uuidString, requestId: key(pending.requestID), role: "user", content: display, attachmentMeta: metadata, createdAt: Self.now())], id: id)
        updateConversation(id, preview: display)
        try await persist(captured); try check(captured)
        begin(pending, api: api, captured: captured, recoverFirst: false)
    }
    public func retry(_ id: UUID) async throws {
        let (captured, api) = try capture(); try await hydrate(captured)
        guard let pending = vault.pending[key(id)], !isSending(id), !mutations.contains(key(id)) else { return }
        let name = key(id); mutations.insert(name); defer { if bound == captured { mutations.remove(name) } }
        try await persist(captured); try check(captured)
        begin(pending, api: api, captured: captured, recoverFirst: true)
    }
    public func stop(_ id: UUID) {
        guard active else { return }; let name = key(id)
        jobs[name]?.cancel(); jobs[name] = nil; jobTokens[name] = nil; activity[name] = nil
        if let captured = bound { Task { try? await self.persist(captured) } }
    }
    private func begin(_ pending: Pending, api: AssistantAPI, captured: SessionContext, recoverFirst: Bool) {
        let name = key(pending.conversationID), token = UUID(); jobTokens[name] = token; activity[name] = "Помощник думает…"
        jobs[name] = Task { await self.perform(pending, api: api, captured: captured, token: token, recoverFirst: recoverFirst) }
    }
    private func valid(_ pending: Pending, captured: SessionContext, token: UUID) -> Bool { active && bound == captured && jobTokens[key(pending.conversationID)] == token && vault.pending[key(pending.conversationID)]?.requestID == pending.requestID && !Task.isCancelled }
    private func perform(_ initial: Pending, api: AssistantAPI, captured: SessionContext, token: UUID, recoverFirst: Bool) async {
        var pending = initial; let name = key(pending.conversationID)
        defer { if bound == captured, jobTokens[name] == token { jobs[name] = nil; jobTokens[name] = nil; activity[name] = nil } }
        do {
            if recoverFirst, await recover(pending, api: api, captured: captured, token: token) { return }
            guard valid(pending, captured: captured, token: token) else { return }
            // A retry replaces a partial stream for this request; it never appends a second answer.
            vault.messages[name]?.removeAll { $0.role == "assistant" && $0.requestId?.lowercased() == key(pending.requestID) }
            while pending.cycle <= 2 {
                let envelope: AssistantAPIRunEnvelope
                do {
                    envelope = try await api.runStreaming(message: pending.message, conversationID: pending.conversationID, requestID: pending.requestID, currentScreen: "assistant", image: pending.cycle == 0 ? pending.image : nil, document: pending.document, toolResults: pending.toolResults) { delta in
                        guard self.valid(pending, captured: captured, token: token) else { return }
                        let existing = self.vault.messages[name]?.first { $0.role == "assistant" && $0.requestId?.lowercased() == self.key(pending.requestID) }
                        self.answer((existing?.content ?? "") + delta, pending: pending)
                        self.activity[name] = nil
                    }
                } catch {
                    guard valid(pending, captured: captured, token: token) else { return }
                    // Only an endpoint-level rejection permits an automatic non-streaming fallback.
                    guard case AppServiceError.http(let status, _) = error, [404, 405, 406, 501].contains(status ?? 0) else { throw error }
                    envelope = try await api.run(message: pending.message, conversationID: pending.conversationID, requestID: pending.requestID, currentScreen: "assistant", image: pending.cycle == 0 ? pending.image : nil, document: pending.document, toolResults: pending.toolResults)
                }
                guard valid(pending, captured: captured, token: token) else { return }
                switch envelope.result {
                case .answer(let text, let truncated, let sources, let knowledge, _, let status):
                    var metadata: [String: AssistantJSONValue] = [:]
                    if !sources.isEmpty { metadata["sources"] = .array(sources.map { .string($0) }) }
                    if let knowledge { metadata["knowledge"] = knowledge.jsonValue }
                    answer(text + (truncated ? "\n\nОтвет сокращён до установленного лимита." : ""), pending: pending, metadata: metadata.isEmpty ? nil : .object(metadata), timestamp: envelope.messageTimestamps?.assistant)
                    applyStatus(status, id: pending.conversationID)
                case .blocked(let text, let status): answer(text, pending: pending, timestamp: envelope.messageTimestamps?.assistant); applyStatus(status, id: pending.conversationID)
                case .conversationFull(let text, let status):
                    vault.messages[name]?.removeAll { $0.requestId?.lowercased() == key(pending.requestID) }; applyStatus(status, id: pending.conversationID); report(text)
                case .toolRequest(let requests, _, let status):
                    applyStatus(status, id: pending.conversationID)
                    guard pending.cycle < 2, !requests.isEmpty else { throw AppServiceError.message("Не удалось получить необходимые данные за два шага.") }
                    activity[name] = "Загрузка источников…"
                    let results = try await executeTools(Array(requests.prefix(4)), captured)
                    guard valid(pending, captured: captured, token: token) else { return }
                    pending.toolResults = results; pending.cycle += 1; vault.pending[name] = pending
                    try await persist(captured); guard valid(pending, captured: captured, token: token) else { return }
                    activity[name] = "Помощник думает…"; continue
                }
                vault.pending[name] = nil
                if let timestamps = envelope.messageTimestamps { applyTimestamps(timestamps, id: pending.conversationID, requestID: pending.requestID) }
                try await persist(captured); return
            }
        } catch {
            guard valid(pending, captured: captured, token: token) else { return }
            if DomainHTTPClient.isUnauthorized(error) { authFailure(); return }
            if await recover(pending, api: api, captured: captured, token: token) { return }
            guard valid(pending, captured: captured, token: token) else { return }
            report(error.localizedDescription); try? await persist(captured)
        }
    }
    private func recover(_ pending: Pending, api: AssistantAPI, captured: SessionContext, token: UUID) async -> Bool {
        for delay in [250, 500, 750, 1000] {
            do {
                try await Task.sleep(for: .milliseconds(delay)); guard valid(pending, captured: captured, token: token) else { return false }
                let page = try await api.messages(conversationID: pending.conversationID)
                guard valid(pending, captured: captured, token: token) else { return false }
                guard page.messages.contains(where: { $0.role == "assistant" && $0.requestId?.lowercased() == key(pending.requestID) }) else { continue }
                mergeMessages(page.messages, id: pending.conversationID); applyStatus(page.conversation, id: pending.conversationID); vault.pending[key(pending.conversationID)] = nil
                try? await persist(captured); return true
            } catch { if active, bound == captured, DomainHTTPClient.isUnauthorized(error) { authFailure(); return false } }
        }
        return false
    }
    private func answer(_ text: String, pending: Pending, metadata: AssistantJSONValue? = nil, timestamp: String? = nil) {
        mergeMessages([AssistantAPIMessage(id: "local-assistant-" + pending.requestID.uuidString, requestId: key(pending.requestID), role: "assistant", content: text, attachmentMeta: metadata, createdAt: timestamp ?? Self.now())], id: pending.conversationID)
        updateConversation(pending.conversationID, preview: text)
    }
    private func updateConversation(_ id: UUID, preview: String) {
        conversationRevisions[key(id)] = UUID()
        let compact = preview.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines), now = Self.now()
        let old = vault.conversations.first { $0.id == id }
        vault.conversations.removeAll { $0.id == id }
        vault.conversations.insert(AssistantAPIConversation(id: id, title: old?.title ?? String(compact.prefix(80)), preview: String(compact.prefix(140)), lastMessageAt: now, createdAt: old?.createdAt ?? now, usedTokens: old?.usedTokens, tokenLimit: old?.tokenLimit, isFull: old?.isFull, contextTokens: old?.contextTokens, compressionThreshold: old?.compressionThreshold, compactions: old?.compactions, willCompressOnNextRun: old?.willCompressOnNextRun), at: 0)
    }
    private func applyStatus(_ status: AssistantAPIConversationStatus?, id: UUID) { if let status, let index = vault.conversations.firstIndex(where: { $0.id == id }) { vault.conversations[index] = vault.conversations[index].updating(status: status) } }
    private func applyTimestamps(_ timestamps: AssistantAPIMessageTimestamps, id: UUID, requestID: UUID) {
        vault.messages[key(id)] = messages(id).map { value in
            guard value.requestId?.lowercased() == key(requestID), let date = value.role == "user" ? timestamps.user : timestamps.assistant else { return value }
            return AssistantAPIMessage(id: value.id, requestId: value.requestId, role: value.role, content: value.content, attachmentMeta: value.attachmentMeta, createdAt: date)
        }
    }
    public func rename(_ id: UUID, title: String) async throws {
        let (captured, api) = try capture(); let name = key(id), value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !value.isEmpty, !isSending(id), !mutations.contains(name) else { throw GsmFuelError.busy }
        mutations.insert(name); conversationRevisions[name] = UUID(); defer { if bound == captured { mutations.remove(name) } }
        do { try await api.renameConversation(id, title: value); try check(captured); conversationRevisions[name] = UUID(); if let index = vault.conversations.firstIndex(where: { $0.id == id }) { vault.conversations[index] = vault.conversations[index].updating(title: value) }; try await persist(captured) }
        catch { try check(captured); handle(error, captured); throw error }
    }
    public func delete(_ id: UUID) async throws {
        let (captured, api) = try capture(); let name = key(id)
        guard !isSending(id), !mutations.contains(name) else { throw GsmFuelError.busy }
        mutations.insert(name); defer { if bound == captured { mutations.remove(name) } }
        do {
            do { try await api.deleteConversation(id) } catch AppServiceError.http(let status, _) where status == 404 {}
            try check(captured); deletedConversations.insert(id); conversationRevisions[name] = UUID(); vault.conversations.removeAll { $0.id == id }; vault.messages[name] = nil; vault.pending[name] = nil; messageCursors[name] = nil; loaded.remove("messages:" + name); try await persist(captured)
        } catch { try check(captured); handle(error, captured); throw error }
    }
    public func feedback(_ value: AssistantKnowledgeFeedback, message: AssistantAPIMessage, conversationID id: UUID) async throws {
        guard let reference = Self.knowledge(message), let claim = reference.primaryClaim else { return }
        let (captured, api) = try capture(); let name = "feedback:" + message.id, identity = name + "|" + value.rawValue
        guard !mutations.contains(name) else { throw GsmFuelError.busy }
        mutations.insert(name); defer { if bound == captured { mutations.remove(name) } }
        let requestID = vault.feedbackIDs[identity] ?? UUID(); vault.feedbackIDs[identity] = requestID
        do {
            try await persist(captured)
            try await api.submitKnowledgeFeedback(claimID: claim.id, answerTraceID: reference.answerTraceId, feedback: value, conversationID: id, clientRequestID: requestID); try check(captured)
            if let index = vault.messages[key(id)]?.firstIndex(where: { $0.id == message.id }) {
                let old = vault.messages[key(id)]![index]; var metadata: [String: AssistantJSONValue] = [:]
                if case .object(let fields) = old.attachmentMeta { metadata = fields }; metadata["knowledgeFeedback"] = .string(value.rawValue)
                vault.messages[key(id)]![index] = AssistantAPIMessage(id: old.id, requestId: old.requestId, role: old.role, content: old.content, attachmentMeta: .object(metadata), createdAt: old.createdAt)
            }
            try await persist(captured)
        } catch { try check(captured); handle(error, captured); throw error }
    }
    public static func knowledge(_ message: AssistantAPIMessage) -> AssistantAPIKnowledgeReference? {
        guard case .object(let fields) = message.attachmentMeta, let value = fields["knowledge"], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(AssistantAPIKnowledgeReference.self, from: data)
    }
    private func handle(_ error: Error, _ captured: SessionContext) { guard active, bound == captured, !AppErrorClassification.isCancellation(error) else { return }; if DomainHTTPClient.isUnauthorized(error) { authFailure() } else { report(error.localizedDescription) } }
    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
