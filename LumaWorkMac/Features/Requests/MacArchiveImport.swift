import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import EngineerCore

@MainActor @Observable
final class MacArchiveImport {
    private(set) var isBusy = false
    private(set) var isApplying = false
    private(set) var error: String?
    var preview: ArchiveImportPreview?
    @ObservationIgnored private var context: SessionContext?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var panel: NSOpenPanel?
    @ObservationIgnored private var readTask: Task<ArchiveImportPreview, Error>?
    func reset() {
        operation = nil; readTask?.cancel(); readTask = nil; panel?.cancel(nil); panel = nil
        context = nil; preview = nil; error = nil; isBusy = false; isApplying = false
    }
    func choose(coordinator: EngineerApplicationCoordinator) {
        guard !isBusy, let context = coordinator.context, let window = NSApp.keyWindow else { return }
        let id = UUID(); operation = id; self.context = context; isBusy = true; error = nil
        Task {
            defer { if operation == id { isBusy = false; panel = nil; readTask = nil } }
            guard operation == id, coordinator.accepts(context), window.isVisible else { return }
            let panel = NSOpenPanel(); self.panel = panel
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url, operation == id, coordinator.accepts(context), window.isVisible else { return }
            do {
                let task = Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try Task.checkCancellation()
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    return try ArchiveImportPreview.parse(data: Data(contentsOf: url, options: .mappedIfSafe), fileName: url.lastPathComponent)
                }; readTask = task
                let result = try await task.value
                guard operation == id, coordinator.accepts(context), window.isVisible else { return }
                preview = result
            } catch {
                guard operation == id, coordinator.accepts(context), !AppErrorClassification.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func apply(repository: RequestsRepository, coordinator: EngineerApplicationCoordinator) async {
        guard !isApplying, let preview, let context, let id = operation, coordinator.accepts(context) else { return }
        isApplying = true; error = nil
        defer { if operation == id { isApplying = false } }
        do {
            try await repository.importArchive(preview, expectedContext: context)
            guard operation == id, coordinator.accepts(context) else { return }
            self.preview = nil
        } catch {
            guard operation == id, coordinator.accepts(context), !AppErrorClassification.isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }
}

struct MacArchiveImportPreview: View {
    let preview: ArchiveImportPreview
    let repository: RequestsRepository
    let coordinator: EngineerApplicationCoordinator
    @Bindable var model: MacArchiveImport
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Импорт закрытых заявок").font(.title2)
            Text(preview.fileName).foregroundStyle(.secondary)
            Text("Заявок: \(preview.records.count). Дубли: \(preview.duplicateCount); использована последняя строка.")
            Text("Записи объединятся с личным архивом по номеру заявки. Совпадающие номера будут обновлены.").foregroundStyle(.secondary)
            Table(Array(preview.records.prefix(20))) {
                TableColumn("Номер", value: \.number)
                TableColumn("Статус", value: \.state)
                TableColumn("Выполнена", value: \.resolvedAt)
            }.frame(height: 230)
            if preview.records.count > 20 { Text("Показаны первые 20 заявок.").font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Отмена") { model.reset() }.keyboardShortcut(.cancelAction).disabled(model.isApplying)
                Spacer()
                if model.isApplying { ProgressView().controlSize(.small) }
                Button("Импортировать") { Task { await model.apply(repository: repository, coordinator: coordinator) } }
                    .keyboardShortcut(.defaultAction).disabled(model.isApplying || preview.records.isEmpty)
            }
        }.padding(20).frame(width: 650).interactiveDismissDisabled(model.isApplying)
    }
}
