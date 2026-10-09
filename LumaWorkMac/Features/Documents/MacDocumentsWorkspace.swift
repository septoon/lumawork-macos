import SwiftUI
import AppKit
import EngineerCore

struct MacDocumentPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let mimeType: String
}
@MainActor @Observable
final class MacDocumentsWorkspace {
    var selection: String?
    var search = ""
    var upload: DocumentUpload?
    var replacing: ServerDocument?
    var editing: ServerDocument?
    var preview: MacDocumentPreviewItem?
    var isPresented = false
    var isBusy = false
    var progress: Double = 0
    var error: String?
    var notice: String?
    let fileAccess = MacFileAccess()
    private var task: Task<Void, Never>?
    private var operation: UUID?
    private var previewDirectory: URL?
    var hasDirty: Bool { upload != nil || editing != nil }
    func clearPreview() {
        preview = nil
        if let previewDirectory { MacImageAdapter.remove(file: previewDirectory); try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
    func discardDraft() { upload = nil; replacing = nil; editing = nil }
    func reset() {
        operation = nil; task?.cancel(); task = nil; fileAccess.reset(); clearPreview(); discardDraft()
        isBusy = false; progress = 0; error = nil; notice = nil; selection = nil; search = ""; isPresented = false
    }
    private func valid(_ captured: SessionContext, coordinator: EngineerApplicationCoordinator, repository: DocumentsRepository, collection: DocumentCollection, grant: SalaryAccessGrant?) -> Bool {
        coordinator.accepts(captured) && repository.permits(collection, grant: grant)
    }
    func choose(collection: DocumentCollection, replacing: ServerDocument?, repository: DocumentsRepository, coordinator: EngineerApplicationCoordinator, grant: SalaryAccessGrant?) {
        guard !isBusy, let captured = coordinator.context, let window = NSApp.keyWindow else { return }
        run(captured: captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) {
            guard var value = try await self.fileAccess.choose(collection: collection, window: window, valid: { self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) }) else { return }
            guard self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { throw CancellationError() }
            if let replacing { value.category = replacing.category ?? value.category; value.kind = replacing.kind ?? value.kind; value.title = replacing.title ?? value.title; value.month = replacing.month ?? value.month }
            self.replacing = replacing; self.upload = value
        }
    }
    func send(_ value: DocumentUpload, collection: DocumentCollection, repository: DocumentsRepository, coordinator: EngineerApplicationCoordinator, grant: SalaryAccessGrant?) {
        guard let captured = coordinator.context else { return }
        let replacing = replacing
        run(captured: captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) {
            try await repository.upload(value, collection: collection, replacing: replacing, grant: grant) { self.progress = $0 }
            guard self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { throw CancellationError() }
            self.discardDraft(); self.notice = "Документ сохранён."
        }
    }
    func download(_ value: ServerDocument, export: Bool, collection: DocumentCollection, repository: DocumentsRepository, coordinator: EngineerApplicationCoordinator, grant: SalaryAccessGrant?) {
        guard let captured = coordinator.context, let window = NSApp.keyWindow else { return }
        run(captured: captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) {
            let file = try await repository.download(value, collection: collection, grant: grant)
            defer { try? FileManager.default.removeItem(at: file) }
            guard self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { throw CancellationError() }
            if export {
                if try await self.fileAccess.save(file: file, name: value.fileName, window: window, valid: { self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) }) { self.notice = "Файл сохранён на Mac." }
            } else {
                self.clearPreview()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EngineerMac-DocumentPreviews", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.previewDirectory = directory
                let name = (value.fileName as NSString).lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { throw GsmFuelError.invalidResponse }
                let destination = directory.appendingPathComponent(name)
                try FileManager.default.moveItem(at: file, to: destination)
                self.preview = MacDocumentPreviewItem(url: destination, title: value.displayName, mimeType: value.mimeType)
            }
        }
    }
    func remove(_ value: ServerDocument, collection: DocumentCollection, repository: DocumentsRepository, coordinator: EngineerApplicationCoordinator, grant: SalaryAccessGrant?) {
        guard let captured = coordinator.context else { return }
        run(captured: captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) {
            try await repository.delete(value, collection: collection, grant: grant)
            guard self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { throw CancellationError() }
            self.selection = nil; self.clearPreview(); self.notice = "Документ удалён."
        }
    }
    func update(_ base: ServerDocument, category: WorkDocumentCategory, title: String, repository: DocumentsRepository, coordinator: EngineerApplicationCoordinator) {
        guard let captured = coordinator.context else { return }
        run(captured: captured, coordinator: coordinator, repository: repository, collection: .work, grant: nil) {
            try await repository.update(base, category: category, title: title)
            guard self.valid(captured, coordinator: coordinator, repository: repository, collection: .work, grant: nil) else { throw CancellationError() }
            self.editing = nil; self.notice = "Название и категория сохранены."
        }
    }
    private func run(captured: SessionContext, coordinator: EngineerApplicationCoordinator, repository: DocumentsRepository, collection: DocumentCollection, grant: SalaryAccessGrant?, body: @escaping () async throws -> Void) {
        guard !isBusy, valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { return }
        let id = UUID(); operation = id; isBusy = true; error = nil; notice = nil; progress = 0
        task = Task {
            defer { if self.operation == id { self.isBusy = false; self.operation = nil; self.task = nil } }
            do { try Task.checkCancellation(); guard self.operation == id, self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant) else { throw CancellationError() }; try await body() }
            catch { if self.operation == id, self.valid(captured, coordinator: coordinator, repository: repository, collection: collection, grant: grant), !AppErrorClassification.isCancellation(error) { self.error = repository.error(collection, grant: grant) ?? error.localizedDescription } }
        }
    }
}
