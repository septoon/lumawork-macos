import SwiftUI
import EngineerCore

struct MacFeedbackScreen: View {
    @Bindable var model: MacFeedbackWorkspace
    let container: MacSessionContainer
    @Binding var slotID: String
    private var slot: UUID { UUID(uuidString: slotID) ?? UUID() }
    let initialArea: FeedbackArea
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    private var repository: FeedbackRepository { container.feedback }
    private var selected: FeedbackMessage? { repository.messages.first { $0.id == model.selection } }
    private var messages: [FeedbackMessage] {
        repository.messages.filter { model.search.isEmpty || ($0.title + " " + $0.number + " " + $0.message).localizedCaseInsensitiveContains(model.search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Обратная связь").font(.headline)
                if repository.isLoading || model.isLoadingDraft { ProgressView().controlSize(.small) }
                Spacer()
                Button("Обновить") { Task { try? await repository.load(force: true) } }.disabled(repository.isLoading)
                Button("Готово") {
                    Task { do { try await model.persist(container: container); dismiss() } catch { container.notices.show(error.localizedDescription) } }
                }.disabled(model.busy || model.isPreparing || model.isLoadingDraft).keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Button { model.selection = nil } label: { Label(model.pending.attempted ? "Повторить отправку" : "Новое сообщение", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading) }.padding(12)
                    TextField("Поиск сообщений", text: $model.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                    List(selection: $model.selection) {
                        ForEach(messages) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text("\(item.number) · \(item.status.title)").font(.caption).foregroundStyle(.secondary)
                            }.tag(item.id)
                        }
                    }
                    if repository.messages.isEmpty, !repository.isLoading {
                        Text(repository.error ?? "Отправленных сообщений пока нет.").font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                }.frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                Group {
                    if let selected {
                        VStack(spacing: 0) {
                            MacFeedbackNarrative(message: selected, openAttachment: openAttachment)
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Дополнение к сообщению", text: $model.addition, axis: .vertical).lineLimit(3...6)
                                HStack {
                                    Button("Отправить дополнение") { add(to: selected) }
                                        .disabled(model.busy || !(3...4000).contains(model.addition.trimmingCharacters(in: .whitespacesAndNewlines).count) || repository.uncertainAdditions.contains(selected.id))
                                    Spacer()
                                    Button("Повторить как новое") {
                                        guard !model.pending.draft.hasContent && model.pending.images.isEmpty else { container.notices.show("Сначала отправьте или удалите сохранённый черновик."); return }
                                        model.pending = FeedbackPending(draft: selected.resendDraft); model.selection = nil
                                    }.disabled(model.busy)
                                }
                                if repository.uncertainAdditions.contains(selected.id) { Text("Результат отправки неизвестен. Обновите список и проверьте дополнения перед повтором.").font(.callout).foregroundStyle(.secondary) }
                            }.padding(16)
                        }
                    } else if let error = model.draftLoadError {
                        ContentUnavailableView { Label("Черновик недоступен", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("Повторить чтение") { Task { await model.load(slot: slot, initialArea: initialArea, container: container) } } }
                    } else { composer }
                }.frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, idealWidth: 1020, minHeight: 640, idealHeight: 740)
        .interactiveDismissDisabled(model.hasDirty || model.busy || model.isPreparing)
        .overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }
        .task(id: slot) { await model.load(slot: slot, initialArea: initialArea, container: container); try? await repository.load() }
        .onChange(of: model.pending) { _, _ in
            guard !model.isLoadingDraft, !model.busy else { return }
            Task { do { try await model.persist(container: container) } catch { if !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } } }
        }
        .sheet(item: $model.preview, onDismiss: { model.cleanPreview() }) { item in MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) }
        .confirmationDialog(model.pending.attempted ? "Отказаться от повторной отправки? Сообщение могло уже попасть на сервер." : "Удалить черновик и вложения?", isPresented: $confirmsDiscard) {
            Button("Удалить локальный черновик", role: .destructive) { Task { do { try await model.discard(container: container) } catch { container.notices.show(error.localizedDescription) } } }
        }
        .onDisappear { model.cleanPreview() }
    }
    private var composer: some View {
        VStack(spacing: 0) {
            if !repository.availableDrafts.isEmpty {
                HStack {
                    Menu("Восстановить сохранённый черновик…") {
                        ForEach(repository.availableDrafts) { item in
                            Button((item.title.isEmpty ? "Без заголовка" : item.title) + (item.attempted ? " · повтор отправки" : "")) { slotID = item.id.uuidString }
                        }
                    }.disabled(model.busy || model.isPreparing || model.pending.hasContent)
                    Text("Черновики из закрытых окон").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12)
            }
            if model.pending.attempted {
                Text("Попытка отправки уже была. Повтор использует тот же ID и сохранённые вложения; текст заморожен до подтверждения результата.").font(.callout).foregroundStyle(.secondary).padding(16)
            }
            Form {
                Section("Сообщение") {
                    Picker("Тип", selection: $model.pending.draft.kind) { ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) } }
                    TextField("Заголовок", text: $model.pending.draft.title)
                    TextField("Описание", text: $model.pending.draft.message, axis: .vertical).lineLimit(5...12)
                    if model.pending.draft.kind.needsReproductionSteps {
                        TextField("Как воспроизвести", text: $model.pending.draft.reproductionSteps, axis: .vertical).lineLimit(3...8)
                        TextField("Ожидаемый результат", text: $model.pending.draft.expectedResult, axis: .vertical).lineLimit(2...6)
                    }
                }
                Section("Разделы приложения") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading) {
                        ForEach(FeedbackArea.allCases.filter { $0 != .users || container.coordinator.session?.user.canAccessAdminPanel == true }) { area in
                            Toggle(area.title, isOn: Binding(get: { model.pending.draft.areas.contains(area) }, set: { if $0 { model.pending.draft.areas.insert(area) } else { model.pending.draft.areas.remove(area) } })).toggleStyle(.checkbox)
                        }
                    }
                    if model.pending.draft.areas.contains(.other) { TextField("Другой раздел", text: $model.pending.draft.otherArea) }
                    Picker("Влияние", selection: $model.pending.draft.impact) { ForEach(FeedbackImpact.allCases) { Text($0.title).tag($0) } }
                    Picker("Частота", selection: $model.pending.draft.frequency) { ForEach(FeedbackFrequency.allCases) { Text($0.title).tag($0) } }
                }
                Section("Снимки экрана") {
                    Text("До четырёх изображений. Можно выбрать файл или перетащить его сюда.").font(.callout).foregroundStyle(.secondary)
                    ForEach(model.pending.images) { image in
                        HStack {
                            Label(image.fileName, systemImage: "photo"); Text(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file)).foregroundStyle(.secondary)
                            Spacer(); Button("Убрать") { model.pending.images.removeAll { $0.id == image.id } }.buttonStyle(.borderless)
                        }
                    }
                    Button("Добавить снимок…") { model.choose(container: container) }.disabled(model.pending.images.count >= 4 || model.isPreparing)
                    if model.isPreparing { ProgressView("Подготовка изображения…") }
                }
            }.formStyle(.grouped).disabled(model.busy || model.isPreparing || model.isLoadingDraft || model.pending.attempted)
                .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first, !model.pending.attempted else { return false }; model.choose(container: container, url: url); return true }
            Divider()
            HStack {
                Button("Удалить черновик", role: .destructive) { confirmsDiscard = true }.disabled(model.busy || model.isPreparing)
                Spacer()
                if let progress = repository.progress[slot] { ProgressView(value: progress).frame(width: 100) }
                Button(model.pending.attempted ? "Повторить отправку" : "Отправить") { Task { await model.send(container: container) } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.isPreparing || model.isLoadingDraft || model.pending.draft.validationMessage != nil)
            }.padding(12)
            if let validation = model.pending.draft.validationMessage { Text(validation).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
        }
    }
    private func add(to message: FeedbackMessage) {
        guard let context = container.coordinator.context else { return }
        let text = model.addition; model.busy = true
        Task {
            defer { if container.coordinator.accepts(context) { model.busy = false } }
            do { try await repository.add(text, id: message.id, expectedContext: context); if container.coordinator.accepts(context), model.addition == text { model.addition = "" } } catch {}
        }
    }
    private func openAttachment(_ report: FeedbackMessage, _ attachment: FeedbackAttachment) {
        guard let context = container.coordinator.context else { return }
        Task {
            do {
                let file = try await repository.attachment(reportID: report.id, attachmentID: attachment.id)
                guard container.coordinator.accepts(context), model.isPresented else { try? FileManager.default.removeItem(at: file); return }
                model.presentPreview(MacDocumentPreviewItem(url: file, title: attachment.fileName, mimeType: attachment.mimeType))
            } catch { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
        }
    }
}

struct MacFeedbackNarrative: View {
    let message: FeedbackMessage
    let openAttachment: (FeedbackMessage, FeedbackAttachment) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(message.title).font(.title2.weight(.semibold))
                Text("\(message.number) · \(message.status.title) · \(message.priority.title)").foregroundStyle(.secondary)
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Тип", value: message.kind.title)
                LabeledContent("Разделы", value: message.areaTitles)
                LabeledContent("Влияние", value: message.impact.title)
                LabeledContent("Частота", value: message.frequency.title)
                Divider(); Text(message.message).textSelection(.enabled)
                if let steps = message.reproductionSteps, !steps.isEmpty { Text("Как воспроизвести").font(.headline); Text(steps).textSelection(.enabled) }
                if let expected = message.expectedResult, !expected.isEmpty { Text("Ожидаемый результат").font(.headline); Text(expected).textSelection(.enabled) }
                if let note = message.adminNote, !note.isEmpty { Text("Заметка администратора").font(.headline); Text(note).textSelection(.enabled) }
                if !message.attachments.isEmpty {
                    Text("Вложения").font(.headline)
                    ForEach(message.attachments) { attachment in Button { openAttachment(message, attachment) } label: { Label(attachment.fileName, systemImage: "photo") } }
                }
                if !message.additions.isEmpty {
                    Text("Дополнения").font(.headline)
                    ForEach(message.additions) { item in
                        VStack(alignment: .leading, spacing: 4) { Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary); Text(item.text).textSelection(.enabled) }
                    }
                }
                if let device = message.deviceInfo {
                    Divider(); Text("\(device.deviceModel) · \(device.osVersion) · \(device.appVersion)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
}
