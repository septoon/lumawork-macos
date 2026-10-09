import SwiftUI
import EngineerCore

struct MacDocumentsView: View {
    @Bindable var model: MacDocumentsWorkspace
    let collection: DocumentCollection
    let repository: DocumentsRepository
    let coordinator: EngineerApplicationCoordinator
    var grant: SalaryAccessGrant? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ServerDocument?
    private var permitted: Bool { repository.permits(collection, grant: grant) }
    private var rows: [ServerDocument] {
        repository.documents(collection, grant: grant).filter { model.search.isEmpty || ($0.displayName + " " + $0.fileName + " " + $0.groupTitle).localizedCaseInsensitiveContains(model.search) }.sorted { ($0.month ?? $0.updatedAt ?? $0.createdAt) > ($1.month ?? $1.updatedAt ?? $1.createdAt) }
    }
    private var selected: ServerDocument? { rows.first { $0.id == model.selection } }
    private var locked: Bool { model.isBusy || repository.busy.contains(collection) || repository.isLoading(collection) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(collection.title).font(.title2)
                Spacer()
                if locked { ProgressView().controlSize(.small) }
                Button("Добавить…") { model.choose(collection: collection, replacing: nil, repository: repository, coordinator: coordinator, grant: grant) }.disabled(locked || repository.requiresRefresh.contains(collection))
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить документы").disabled(locked)
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.hasDirty || model.isBusy)
            }.padding(14)
            Divider()
            if permitted {
                HStack { TextField("Поиск документов", text: $model.search); Spacer(); Text("\(rows.count) документов").foregroundStyle(.secondary) }.padding(12)
                Table(rows, selection: $model.selection) {
                    TableColumn("Название", value: \.displayName)
                    TableColumn(collection == .salary ? "Месяц" : "Категория", value: \.groupTitle).width(min: 130, ideal: 190)
                    TableColumn("Размер") { Text(ByteCountFormatter.string(fromByteCount: Int64($0.sizeBytes), countStyle: .file)) }.width(85)
                }.contextMenu(forSelectionType: String.self) { ids in
                    if let value = rows.first(where: { ids.contains($0.id) }) { actions(value) }
                } primaryAction: { ids in if let value = rows.first(where: { ids.contains($0.id) }) { preview(value) } }
                .overlay { if rows.isEmpty { if repository.isLoading(collection) { ProgressView("Загрузка документов…") } else if let error = repository.error(collection, grant: grant) { ContentUnavailableView("Документы недоступны", systemImage: "exclamationmark.triangle", description: Text(error)) } else { ContentUnavailableView(model.search.isEmpty ? "Нет документов" : "Ничего не найдено", systemImage: "doc") } } }
                HStack {
                    if let selected { actions(selected) }
                    Spacer()
                    if repository.connection(collection, grant: grant) == .offline { Label("Локальный кеш", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                }.padding(12).disabled(locked)
                if let error = model.error ?? repository.error(collection, grant: grant) { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
            } else { ContentUnavailableView("Доступ закрыт", systemImage: "lock").frame(maxHeight: .infinity) }
        }.frame(minWidth: 750, idealWidth: 900, minHeight: 500, idealHeight: 620)
        .interactiveDismissDisabled(model.hasDirty || model.isBusy)
        .task(id: coordinator.context) { repository.synchronizeSession(); try? await repository.load(collection, grant: grant) }
        .onChange(of: permitted) { _, value in if !value { pendingDelete = nil; model.reset(); dismiss() } }
        .onDisappear { model.reset() }
        .sheet(item: $model.preview, onDismiss: { model.clearPreview() }) { item in if permitted { MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) } }
        .sheet(isPresented: Binding(get: { model.upload != nil && permitted }, set: { if !$0 { model.discardDraft() } })) { if let value = model.upload { MacDocumentUploadView(value: value, model: model, collection: collection, repository: repository, coordinator: coordinator, grant: grant) } }
        .sheet(item: $model.editing) { base in MacDocumentMetadataEditor(base: base, model: model, repository: repository, coordinator: coordinator) }
        .confirmationDialog("Удалить документ с сервера?", isPresented: Binding(get: { pendingDelete != nil && permitted }, set: { if !$0 { pendingDelete = nil } })) { Button("Удалить", role: .destructive) { if let value = pendingDelete { model.remove(value, collection: collection, repository: repository, coordinator: coordinator, grant: grant) }; pendingDelete = nil } }
    }
    @ViewBuilder private func actions(_ value: ServerDocument) -> some View {
        Button("Просмотр") { preview(value) }.disabled(locked)
        Button("Сохранить как…") { model.download(value, export: true, collection: collection, repository: repository, coordinator: coordinator, grant: grant) }.disabled(locked)
        if collection == .work { Button("Название и категория…") { model.editing = value }.disabled(locked || repository.requiresRefresh.contains(collection)) }
        Button("Заменить…") { model.choose(collection: collection, replacing: value, repository: repository, coordinator: coordinator, grant: grant) }.disabled(locked || repository.requiresRefresh.contains(collection))
        Button("Удалить…", role: .destructive) { pendingDelete = value }.disabled(locked || repository.requiresRefresh.contains(collection))
    }
    private func refresh() { Task { try? await repository.load(collection, grant: grant, force: true) } }
    private func preview(_ value: ServerDocument) { model.download(value, export: false, collection: collection, repository: repository, coordinator: coordinator, grant: grant) }
}
private struct MacDocumentUploadView: View {
    @State var value: DocumentUpload
    @Bindable var model: MacDocumentsWorkspace
    let collection: DocumentCollection
    let repository: DocumentsRepository
    let coordinator: EngineerApplicationCoordinator
    let grant: SalaryAccessGrant?
    @State private var confirmsDiscard = false
    private var validation: String? { do { try value.validate(for: collection); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.replacing == nil ? "Добавить документ" : "Заменить документ").font(.title2)
            Text(value.fileName).lineLimit(2).textSelection(.enabled)
            Text(ByteCountFormatter.string(fromByteCount: Int64(value.data.count), countStyle: .file)).foregroundStyle(.secondary)
            Form {
                switch collection {
                case .work:
                    TextField("Название", text: $value.title)
                    Picker("Категория", selection: $value.category) { ForEach(WorkDocumentCategory.allCases) { Text($0.title).tag($0) } }
                case .vehicle:
                    Picker("Вид документа", selection: $value.kind) { ForEach(VehicleDocumentKind.allCases) { Text($0.title).tag($0) } }
                case .salary:
                    TextField("Месяц (YYYY-MM)", text: $value.month).disabled(model.replacing != nil)
                }
            }.disabled(model.isBusy)
            if model.replacing != nil { Text("Файл на сервере будет заменён после загрузки нового документа.").foregroundStyle(.secondary) }
            if let error = model.error ?? validation { Text(error).foregroundStyle(.red) }
            if model.isBusy { ProgressView(value: model.progress); Text("Загружено \(Int(model.progress * 100))% частями по 512 КБ").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Отмена") { confirmsDiscard = true }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Spacer()
                if repository.requiresRefresh.contains(collection) { Button("Обновить список") { Task { try? await repository.load(collection, grant: grant, force: true) } }.disabled(repository.isLoading(collection) || model.isBusy) }
                Button(model.replacing == nil ? "Загрузить" : "Заменить") { model.send(value, collection: collection, repository: repository, coordinator: coordinator, grant: grant) }.keyboardShortcut(.defaultAction).disabled(model.isBusy || validation != nil || repository.requiresRefresh.contains(collection) || repository.isLoading(collection))
            }
        }.padding(20).frame(width: 520).interactiveDismissDisabled(true)
        .confirmationDialog("Отбросить выбранный документ?", isPresented: $confirmsDiscard) { Button("Отбросить", role: .destructive) { model.discardDraft() } }
    }
}
private struct MacDocumentMetadataEditor: View {
    let base: ServerDocument
    @Bindable var model: MacDocumentsWorkspace
    let repository: DocumentsRepository
    let coordinator: EngineerApplicationCoordinator
    @State private var title = ""
    @State private var category = WorkDocumentCategory.other
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Название и категория").font(.title2)
            TextField("Название", text: $title)
            Picker("Категория", selection: $category) { ForEach(WorkDocumentCategory.allCases) { Text($0.title).tag($0) } }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { model.editing = nil }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Spacer()
                Button("Сохранить") { model.update(base, category: category, title: title, repository: repository, coordinator: coordinator) }.keyboardShortcut(.defaultAction).disabled(model.isBusy || repository.requiresRefresh.contains(.work) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200)
            }
        }.padding(20).frame(width: 480).interactiveDismissDisabled(true)
        .onAppear { title = base.title ?? base.fileName; category = base.category ?? .other }
    }
}
