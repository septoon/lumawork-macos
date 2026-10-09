import SwiftUI
import EngineerCore

struct MacAdminFeedbackView: View {
    @Bindable var model: MacAdminWorkspace
    let container: MacSessionContainer
    private var repository: AdminRepository { container.admin }
    private var messages: [FeedbackMessage] {
        repository.feedback(grant: model.grant).filter { (model.feedbackStatus == nil || $0.status == model.feedbackStatus) && (model.feedbackKind == nil || $0.kind == model.feedbackKind) && (model.search.isEmpty || ($0.title + " " + $0.message + " " + $0.reporterEmail + " " + $0.number).localizedCaseInsensitiveContains(model.search)) }
    }
    private var selected: FeedbackMessage? { repository.feedback(grant: model.grant).first { $0.id == model.feedbackID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск сообщений", text: $model.search).textFieldStyle(.roundedBorder)
                Picker("Статус", selection: $model.feedbackStatus) {
                    Text("Все статусы").tag(FeedbackStatus?.none)
                    ForEach(FeedbackStatus.allCases.filter { $0 != .draft }) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 200)
                Picker("Тип", selection: $model.feedbackKind) {
                    Text("Все типы").tag(FeedbackKind?.none)
                    ForEach(FeedbackKind.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 240)
            }.padding(12)
            HSplitView {
                List(selection: $model.feedbackID) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.title).lineLimit(2)
                            Text("\(message.number) · \(message.status.title)").font(.caption).foregroundStyle(.secondary)
                        }.tag(message.id)
                    }
                }.frame(minWidth: 230, idealWidth: 280, maxWidth: 400)
                if let message = selected {
                    VStack(spacing: 0) {
                        HStack {
                            Text(message.reporterName ?? message.reporterEmail).textSelection(.enabled)
                            Spacer()
                            if container.coordinator.session?.user.can(.manageFeedback) == true {
                                Button("Обработать…") { model.feedbackEditorID = message.id }.disabled(repository.isSaving || repository.requiresRefresh)
                            }
                        }.padding(12)
                        MacFeedbackNarrative(message: message, openAttachment: openAttachment)
                        Divider()
                        Text(message.emailStatus.title + (message.emailError.map { ": " + $0 } ?? "")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(12)
                    }.frame(minWidth: 380, maxWidth: .infinity)
                } else { ContentUnavailableView(messages.isEmpty ? "Сообщений нет" : "Выберите сообщение", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }
    private func openAttachment(_ report: FeedbackMessage, _ attachment: FeedbackAttachment) {
        guard let context = container.coordinator.context else { return }
        let generation = repository.accessGeneration, selected = model.feedbackID
        Task {
            do {
                let file = try await repository.attachment(reportID: report.id, attachmentID: attachment.id, grant: model.grant)
                guard container.coordinator.accepts(context), generation == repository.accessGeneration, selected == model.feedbackID, model.page == .feedback else { try? FileManager.default.removeItem(at: file); return }
                model.presentPreview(MacDocumentPreviewItem(url: file, title: attachment.fileName, mimeType: attachment.mimeType))
            } catch { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
        }
    }
}
struct MacAdminFeedbackEditor: View {
    let message: FeedbackMessage
    let container: MacSessionContainer
    let grant: ProtectedAccessGrant?
    @Environment(\.dismiss) private var dismiss
    @State private var status: FeedbackStatus = .new
    @State private var priority: FeedbackPriority = .normal
    @State private var note = ""
    @State private var busy = false
    @State private var confirmsEmail = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("\(message.number): \(message.title)").font(.headline); Spacer(); Button("Отмена") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction) }.padding(16)
            Form {
                Picker("Статус", selection: $status) { ForEach(FeedbackStatus.allCases.filter { $0 != .draft }) { Text($0.title).tag($0) } }
                Picker("Приоритет", selection: $priority) { ForEach(FeedbackPriority.allCases) { Text($0.title).tag($0) } }
                TextField("Заметка администратора", text: $note, axis: .vertical).lineLimit(6...12)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(busy)
            HStack {
                Button("Повторить отправку письма…") { confirmsEmail = true }.disabled(busy || container.admin.requiresRefresh)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Сохранить") { run(retry: false) }.disabled(busy || note.count > 4000 || container.admin.requiresRefresh)
            }.padding(16)
        }.frame(width: 620, height: 480)
        .interactiveDismissDisabled(busy || status != message.status || priority != message.priority || note != (message.adminNote ?? ""))
        .onAppear { status = message.status; priority = message.priority; note = message.adminNote ?? "" }
        .confirmationDialog("Повторно поставить письмо по \(message.number) в очередь?", isPresented: $confirmsEmail) { Button("Повторить отправку") { run(retry: true) } }
        .overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }
    }
    private func run(retry: Bool) {
        guard !busy, let context = container.coordinator.context else { return }
        let generation = container.admin.accessGeneration; busy = true
        Task {
            defer { if container.coordinator.accepts(context), container.admin.accessGeneration == generation { busy = false } }
            do {
                if retry { try await container.admin.retryFeedbackEmail(id: message.id, grant: grant, expectedContext: context) }
                else { try await container.admin.updateFeedback(id: message.id, status: status, priority: priority, note: note, grant: grant, expectedContext: context) }
                guard container.coordinator.accepts(context), container.admin.accessGeneration == generation else { return }; dismiss()
            } catch { if container.coordinator.accepts(context), container.admin.accessGeneration == generation, !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
