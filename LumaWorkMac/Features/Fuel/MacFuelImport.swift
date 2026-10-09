import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EngineerCore

@MainActor @Observable
final class MacFuelImport: Identifiable {
    let id = UUID()
    let context: SessionContext
    var uploads: [FuelImportUpload] = []
    var items: [FuelImportPreviewItem] = []
    var corrections: [FuelImportCorrection] = []
    var replacements: Set<String> = []
    var selection: String?
    var result: FuelImportCommitResponse?
    var error: String?
    var busy = false
    private var operation: UUID?
    private var panel: NSOpenPanel?
    private var readTask: Task<[FuelImportUpload], Error>?
    init(context: SessionContext) { self.context = context }
    var hasDirty: Bool { !uploads.isEmpty && result == nil }
    func reset() { operation = nil; readTask?.cancel(); panel?.cancel(nil); panel = nil; readTask = nil; uploads = []; items = []; corrections = []; replacements = []; result = nil; busy = false }
    func choose(repository: GsmFuelRepository, coordinator: EngineerApplicationCoordinator) {
        guard !busy, coordinator.accepts(context), let window = NSApp.keyWindow else { return }
        busy = true; error = nil; let id = UUID(); operation = id
        Task {
            defer { if operation == id { busy = false; panel = nil; readTask = nil } }
            let panel = NSOpenPanel(); self.panel = panel; panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            guard response == .OK, operation == id, coordinator.accepts(context), window.isVisible else { return }
            let urls = panel.urls
            do {
                let task = Task.detached(priority: .userInitiated) {
                    guard (1...20).contains(urls.count) else { throw AppServiceError.message("Выберите от 1 до 20 XLSX-файлов.") }
                    var total = 0
                    return try urls.map { url in
                        try Task.checkCancellation()
                        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 6 * 1024 * 1024 else { throw AppServiceError.message("Каждый XLSX должен быть не больше 6 МБ.") }
                        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                        let data = try handle.read(upToCount: 6 * 1024 * 1024 + 1) ?? Data(); total += data.count
                        guard data.count <= 6 * 1024 * 1024, total <= 7 * 1024 * 1024 else { throw AppServiceError.message("Общий размер XLSX не должен превышать 7 МБ.") }
                        return FuelImportUpload(fileName: url.lastPathComponent, dataBase64: data.base64EncodedString())
                    }
                }; readTask = task
                let value = try await task.value
                guard operation == id, coordinator.accepts(context), window.isVisible else { return }
                uploads = value; items = []; corrections = []; replacements = []; result = nil
                let preview = try await repository.previewImports(value, expectedContext: context)
                guard operation == id, coordinator.accepts(context), window.isVisible else { return }
                apply(preview)
            } catch { if operation == id, coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    private func apply(_ preview: [FuelImportPreviewItem]) { items = preview; corrections = preview.map(FuelImportCorrection.init); replacements = []; selection = items.first?.id; result = nil }
    func preview(repository: GsmFuelRepository, coordinator: EngineerApplicationCoordinator) async {
        guard !busy, !uploads.isEmpty, coordinator.accepts(context) else { return }
        let id = UUID(); operation = id; busy = true; error = nil
        defer { if operation == id { busy = false } }
        do { let value = try await repository.previewImports(uploads, expectedContext: context); guard operation == id, coordinator.accepts(context) else { return }; apply(value) }
        catch { if operation == id, coordinator.accepts(context) { self.error = error.localizedDescription } }
    }
    var changedCorrections: [FuelImportCorrection] {
        zip(corrections, items).compactMap { edited, item in
            let original = FuelImportCorrection(item: item)
            guard edited != original else { return nil }
            let byRow = Dictionary(uniqueKeysWithValues: original.entries.map { ($0.row, $0) })
            var changed = edited; changed.entries = edited.entries.filter { byRow[$0.row] != $0 }
            return changed
        }
    }
    var validationError: String? { do {
        for (edited, item) in zip(corrections, items) where item.period != nil && edited.period == nil { throw AppServiceError.message("Укажите месяц отчёта в формате YYYY-MM.") }
        for item in changedCorrections { _ = try FuelImportService.correctionPayload(item) }; return nil } catch { return error.localizedDescription } }
    func commit(repository: GsmFuelRepository, coordinator: EngineerApplicationCoordinator) async {
        guard !busy, !items.isEmpty, validationError == nil, coordinator.accepts(context) else { return }
        let id = UUID(); operation = id; busy = true; error = nil
        defer { if operation == id { busy = false } }
        do { let value = try await repository.commitImports(uploads, replacing: replacements, corrections: changedCorrections, expectedContext: context); guard operation == id, coordinator.accepts(context) else { return }; result = value }
        catch { if operation == id, coordinator.accepts(context) { self.error = repository.requiresImportReview ? "Результат отправки неизвестен. Повторите предпросмотр для проверки сервера." : error.localizedDescription } }
    }
}

struct MacFuelImportScreen: View {
    @Bindable var model: MacFuelImport
    let repository: GsmFuelRepository
    let coordinator: EngineerApplicationCoordinator
    let close: () -> Void
    @State private var confirmsImport = false
    @State private var confirmsClose = false
    private var index: Int? { model.items.firstIndex { $0.id == model.selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Импорт топлива из XLSX").font(.title2); Spacer(); Button("Выбрать файлы…") { model.choose(repository: repository, coordinator: coordinator) }.disabled(model.busy || repository.isMutating) }
            Text("До 20 отчётов, 6 МБ на файл и 7 МБ суммарно. Изменения записываются только после подтверждения.").font(.callout).foregroundStyle(.secondary)
            if let result = model.result {
                Text("Импортировано месяцев: \(result.importedMonths), заправок: \(result.importedRefuels). Пропущено месяцев: \(result.skippedMonths).")
                List(result.results) { item in VStack(alignment: .leading) { Text(item.fileName).fontWeight(.medium); Text(item.message) } }
            } else if model.items.isEmpty { ContentUnavailableView("Выберите XLSX-отчёты", systemImage: "tablecells") }
            else {
                HSplitView {
                    List(model.items, selection: $model.selection) { item in
                        VStack(alignment: .leading) { Text(item.fileName); Text((item.period ?? "Период не определён") + " · " + status(item.status)).font(.caption).foregroundStyle(.secondary) }.tag(item.id)
                    }.frame(width: 240)
                    if let index { details(index).frame(minWidth: 550) }
                }
            }
            if let error = model.error ?? model.validationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if repository.requiresImportReview, model.result == nil { Text("Перед повторным импортом выполните новый предпросмотр.").foregroundStyle(.secondary) }
            HStack {
                Button("Закрыть") { if model.hasDirty { confirmsClose = true } else { model.reset(); close() } }.keyboardShortcut(.cancelAction).disabled(model.busy || repository.isMutating)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Повторить предпросмотр") { Task { await model.preview(repository: repository, coordinator: coordinator) } }.disabled(model.busy || model.uploads.isEmpty || repository.isMutating)
                Button("Импортировать…") { confirmsImport = true }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || repository.isMutating || model.items.isEmpty || model.result != nil || repository.requiresImportReview || model.validationError != nil)
            }
        }.padding(20).frame(width: 900, height: 600).interactiveDismissDisabled(model.busy || repository.isMutating || model.hasDirty)
        .confirmationDialog("Импортировать отчёты на сервер?", isPresented: $confirmsImport) {
            Button("Импортировать") { Task { await model.commit(repository: repository, coordinator: coordinator) } }
        } message: { Text("Выбрано замен предыдущих импортов: \(model.replacements.count). Остальные конфликты сервер пропустит.") }
        .confirmationDialog("Закрыть предпросмотр без импорта?", isPresented: $confirmsClose) { Button("Закрыть", role: .destructive) { model.reset(); close() } }
        .onDisappear { model.reset() }
    }
    private func details(_ index: Int) -> some View {
        let item = model.items[index]
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.fileName).font(.headline)
                Text("Исходный отчёт: \(item.entries.count) заправок · \(GsmFuelFormatting.number(item.totalLiters)) л · \(GsmFuelFormatting.number(item.totalCost)) ₽")
                ForEach(Array((item.errors + item.warnings).enumerated()), id: \.offset) { _, text in Text(text).foregroundStyle(.secondary) }
                if item.status == .replaceable, let id = item.existingImportId {
                    Toggle("Заменить предыдущий XLSX-импорт", isOn: Binding(get: { model.replacements.contains(id) }, set: { if $0 { model.replacements.insert(id) } else { model.replacements.remove(id) } }))
                }
                if !item.fileHash.isEmpty {
                    TextField("Месяц начисления (YYYY-MM)", text: Binding(get: { model.corrections[index].period ?? "" }, set: { model.corrections[index].period = $0.isEmpty ? nil : $0 })).frame(maxWidth: 300)
                    Text("Исправления строк: дата YYYY-MM-DD, вид топлива, литры, стоимость.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.corrections[index].entries.indices, id: \.self) { row in
                        HStack {
                            Text("\(model.corrections[index].entries[row].row)").frame(width: 30)
                            TextField("Дата", text: $model.corrections[index].entries[row].date).frame(width: 105)
                            TextField("Топливо", text: $model.corrections[index].entries[row].fuelType)
                            TextField("Литры", text: $model.corrections[index].entries[row].liters).frame(width: 75)
                            TextField("Стоимость", text: $model.corrections[index].entries[row].cost).frame(width: 90)
                        }
                    }
                }
            }.padding(10)
        }.disabled(model.busy || repository.isMutating)
    }
    private func status(_ value: FuelImportPreviewItem.Status) -> String {
        switch value { case .ready: return "Готов"; case .warning: return "Предупреждение"; case .duplicate: return "Уже импортирован"; case .conflict: return "Конфликт"; case .replaceable: return "Доступна замена"; case .error: return "Ошибка" }
    }
}
