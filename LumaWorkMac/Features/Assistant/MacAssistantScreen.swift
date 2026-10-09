import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EngineerCore

struct MacAssistantScreen: View {
    @Bindable var model: MacAssistantWorkspace
    let container: MacSessionContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingSelection: UUID?
    @State private var confirmsDiscard = false
    private var repository: AssistantRepository { container.assistant }
    private var sending: Bool { repository.isSending(model.conversationID) }
    private var conversation: AssistantAPIConversation? { repository.conversations.first { $0.id == model.conversationID } }
    private var canSend: Bool { !repository.isDeleted(model.conversationID) && !sending && !model.isPreparing && !model.isEnqueuing && !repository.isMutating(model.conversationID) && !repository.canRetry(model.conversationID) && conversation?.isFull != true && (!model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.image != nil || model.document != nil) }
    var body: some View {
        HSplitView {
            history.frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            VStack(spacing: 0) {
                HStack {
                    Text(repository.isDeleted(model.conversationID) ? "Чат удалён" : conversation?.title ?? "Новый чат").font(.headline).lineLimit(1)
                    Spacer()
                    Button { model.showsWiki = true } label: { Label("Wiki", systemImage: "books.vertical") }
                    Button { Task { try? await repository.loadMessages(model.conversationID, force: true) } } label: { Label("Обновить чат", systemImage: "arrow.clockwise") }.labelStyle(.iconOnly).disabled(sending || repository.isLoading(model.conversationID))
                }.padding(12)
                Divider()
                messages
                Divider()
                composer.padding(12)
            }.frame(minWidth: 420)
        }
        .task { try? await repository.loadConversations(); try? await repository.loadMessages(model.conversationID) }
        .task(id: model.conversationID) { try? await repository.loadMessages(model.conversationID) }
        .sheet(isPresented: $model.showsWiki) { MacWikiScreen(model: model.wiki, container: container) }
        .sheet(item: $model.presentedPreview) { item in MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) }
        .alert("Удалить чат?", isPresented: Binding(get: { model.deleteID != nil }, set: { if !$0 { model.deleteID = nil } })) {
            Button("Удалить", role: .destructive) { if let id = model.deleteID { model.deleteID = nil; let context = container.coordinator.context; run { try await repository.delete(id); if container.coordinator.context == context, model.conversationID == id { model.discardComposer(); model.conversationID = UUID() } } } }
            Button("Отмена", role: .cancel) { model.deleteID = nil }
        } message: { Text("История этого чата будет удалена с сервера.") }
        .alert("Название чата", isPresented: Binding(get: { model.renameID != nil }, set: { if !$0 { model.renameID = nil } })) {
            TextField("Название", text: $model.renameTitle)
            Button("Сохранить") { if let id = model.renameID { let title = model.renameTitle; model.renameID = nil; run { try await repository.rename(id, title: title) } } }
            Button("Отмена", role: .cancel) { model.renameID = nil }
        }
        .confirmationDialog("Удалить черновик сообщения?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Удалить черновик", role: .destructive) { if let id = pendingSelection { model.discardComposer(); model.conversationID = id }; pendingSelection = nil }
            Button("Отмена", role: .cancel) { pendingSelection = nil }
        }
        .onChange(of: model.speech.errorMessage) { _, value in if let value { container.notices.show(value) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in model.speech.reset() }
        .onChange(of: scenePhase) { _, value in if value != .active { model.speech.reset() } }
        .onDisappear { model.speech.reset(); model.cancelPreparation() }
    }
    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Button { select(UUID()) } label: { Label("Новый чат", systemImage: "square.and.pencil") }
                Spacer()
                Button { Task { try? await repository.loadConversations(force: true) } } label: { Label("Обновить историю", systemImage: "arrow.clockwise") }.labelStyle(.iconOnly).disabled(repository.isLoading())
            }.padding(10)
            TextField("Поиск чатов", text: $model.historySearch).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: Binding<UUID?>(get: { model.conversationID }, set: { if let id = $0 { select(id) } })) {
                ForEach(repository.conversations.filter { model.historySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(model.historySearch) || $0.preview.localizedCaseInsensitiveContains(model.historySearch) }) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(item.title).lineLimit(1); if repository.isSending(item.id) { ProgressView().controlSize(.mini) } }
                        Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 3).tag(item.id)
                    .contextMenu {
                        Button("Переименовать") { model.renameTitle = item.title; model.renameID = item.id }.disabled(repository.isSending(item.id))
                        Button("Удалить", role: .destructive) { model.deleteID = item.id }.disabled(repository.isSending(item.id))
                    }.disabled(repository.isMutating(item.id))
                }
                if repository.nextCursor != nil { Button("Загрузить ещё") { Task { try? await repository.loadConversations(more: true) } }.disabled(repository.isLoading()) }
            }.listStyle(.sidebar)
            if repository.isLoading(), repository.conversations.isEmpty { ProgressView().controlSize(.small).padding() }
            if let warning = repository.cacheWarning { Text(warning).font(.caption).foregroundStyle(.secondary).padding(10) }
        }
    }
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if repository.hasOlderMessages(model.conversationID) { Button("Предыдущие сообщения") { Task { try? await repository.loadMessages(model.conversationID, more: true) } }.disabled(repository.isLoading(model.conversationID)) }
                    if repository.messages(model.conversationID).isEmpty {
                        if repository.isLoading(model.conversationID) { ProgressView().padding() }
                        else { Text("Задайте вопрос по заявкам, оборудованию или базе знаний.").foregroundStyle(.secondary).padding(.vertical, 30) }
                    }
                    ForEach(repository.messages(model.conversationID)) { message in
                        MacAssistantMessage(message: message, disabled: sending, feedback: { value in
                            let id = model.conversationID
                            run { try await repository.feedback(value, message: message, conversationID: id) }
                        })
                    }
                    if let status = repository.activity[model.conversationID.uuidString.lowercased()] { HStack { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) } }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(18).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
            }
            // Scroll on a new message, leaving manual scroll position intact while deltas arrive.
            .onChange(of: repository.messages(model.conversationID).count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if repository.isDeleted(model.conversationID) {
                HStack { Text("Этот чат удалён в другом окне.").foregroundStyle(.secondary); Spacer(); Button("Перенести черновик в новый чат") { model.speech.finishForSubmission(); model.conversationID = UUID() } }
            } else if conversation?.isFull == true { Text("Лимит чата исчерпан. Создайте новый чат.").foregroundStyle(.secondary) }
            else if conversation?.willCompressOnNextRun == true { Text("При следующем сообщении контекст чата будет сжат.").font(.caption).foregroundStyle(.secondary) }
            if repository.canRetry(model.conversationID) {
                HStack {
                    Text("Отправка остановлена или результат ещё не подтверждён.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Проверить и повторить") { let id = model.conversationID; run { try await repository.retry(id) } }.disabled(repository.isMutating(model.conversationID))
                }
            }
            if let name = model.attachmentName {
                HStack {
                    Button { model.presentedPreview = model.attachmentPreview } label: { Label(name, systemImage: model.document == nil ? "photo" : "doc") }.lineLimit(1)
                    if model.document?.wasTruncated == true { Text("Текст сокращён").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button { model.clearAttachment() } label: { Label("Убрать вложение", systemImage: "xmark") }.labelStyle(.iconOnly).disabled(model.isEnqueuing)
                }
            }
            MacAssistantComposer(text: $model.text, enabled: !model.isEnqueuing && !model.speech.isActive, submit: send, pasteImage: { data in model.choose(container: container, pasted: data) }).frame(height: 76)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    guard let provider = providers.first, !model.isPreparing, !model.isEnqueuing else { return false }
                    let id = model.conversationID, context = container.coordinator.context
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in Task { @MainActor in guard let url, container.coordinator.context == context, model.conversationID == id else { return }; model.choose(container: container, url: url) } }
                    return true
                }
            HStack {
                Button { model.choose(container: container) } label: { Label("Вложение", systemImage: "paperclip") }.disabled(model.isPreparing || model.isEnqueuing || sending)
                if model.isPreparing { ProgressView().controlSize(.small); Text("Подготовка вложения…").font(.caption).foregroundStyle(.secondary) }
                Button { dictate() } label: { Label(model.speech.isActive ? "Завершить диктовку" : "Диктовка", systemImage: model.speech.isActive ? "stop.circle" : "mic") }.disabled(model.isEnqueuing || sending || model.speech.phase == .preparing || model.speech.phase == .finalizing)
                if model.speech.phase == .recording { ProgressView(value: Double(model.speech.audioLevel)).frame(width: 45); Button("Отменить диктовку") { model.speech.cancel() } }
                Spacer()
                if sending { Button("Остановить") { repository.stop(model.conversationID) } }
                else { Button("Отправить", action: send).buttonStyle(.borderedProminent).disabled(!canSend) }
            }
            Text("Return — отправить · Shift–Return — новая строка · один файл до 12 МБ").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard let context = container.coordinator.context else { return }
        Task { guard container.coordinator.accepts(context) else { return }; do { try await action() } catch { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } } }
    }
    private func select(_ id: UUID) { guard id != model.conversationID else { return }; if model.hasDirty { pendingSelection = id; confirmsDiscard = true } else { model.conversationID = id } }
    private func dictate() {
        if model.speech.phase == .recording { model.speech.finish(); return }
        let context = container.coordinator.context, id = model.conversationID, initial = model.text
        Task { guard context == container.coordinator.context, id == model.conversationID else { return }; await model.speech.start(initialText: initial) { text in guard context == container.coordinator.context, id == model.conversationID else { return }; model.text = text } }
    }
    private func send() {
        guard canSend, let context = container.coordinator.context else { return }
        model.speech.finishForSubmission()
        let id = model.conversationID, text = model.text, image = model.image, document = model.document
        model.isEnqueuing = true
        Task {
            defer { if container.coordinator.accepts(context) { model.isEnqueuing = false } }
            do {
                guard container.coordinator.accepts(context), model.conversationID == id else { return }
                try await repository.send(message: text, image: image, document: document, conversationID: id, expectedContext: context)
                guard container.coordinator.accepts(context), model.conversationID == id else { return }
                model.discardComposer()
            } catch { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
        }
    }
}

private struct MacAssistantMessage: View {
    let message: AssistantAPIMessage
    let disabled: Bool
    let feedback: (AssistantKnowledgeFeedback) -> Void
        private var fields: [String: AssistantJSONValue] { if case .object(let value) = message.attachmentMeta { return value }; return [:] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "user" ? "Вы" : "Помощник").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            MacMarkdownText(text: message.content)
            if case .string(let name) = fields["fileName"] { Label(name, systemImage: "doc").font(.caption).foregroundStyle(.secondary) }
            else if case .string("image") = fields["kind"] { Label("Изображение", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            if case .array(let values) = fields["sources"] {
                ForEach(Array(values.enumerated()), id: \.offset) { _, item in if case .string(let value) = item { MacMarkdownText(text: value).font(.caption).foregroundStyle(.secondary) } }
            }
            if let reference = AssistantRepository.knowledge(message), let claim = reference.primaryClaim {
                HStack {
                    Text(claim.state == "disputed" ? "Знание оспаривается" : claim.state == "candidate" ? "Знание проверяется" : "База знаний").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    feedbackButton(.support, title: "Полезно", icon: "hand.thumbsup")
                    feedbackButton(.contradict, title: "Неверно", icon: "hand.thumbsdown")
                }.disabled(disabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func feedbackButton(_ value: AssistantKnowledgeFeedback, title: String, icon: String) -> some View {
        Button { feedback(value) } label: { Label(title, systemImage: fields["knowledgeFeedback"] == .string(value.rawValue) ? icon + ".fill" : icon) }.buttonStyle(.borderless).help(title)
    }
}

// Native attributed text handles inline links; code blocks preserve whitespace and selection.
struct MacMarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    let code = part.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                    ScrollView(.horizontal) { Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(10) }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text((try? AttributedString(markdown: part, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part)).textSelection(.enabled)
                }
            }
        }.environment(\.openURL, OpenURLAction { url in MacSafeExternalURL.permits(url) ? .systemAction : .discarded })
    }
}
enum MacSafeExternalURL {
    static func permits(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return false }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return !names.contains { ["token", "access_token", "authorization", "api_key", "key"].contains($0) }
    }
}
