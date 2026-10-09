import SwiftUI
import AppKit
import EngineerCore

struct MacTransferQueueView: View {
    @Bindable var workspace: MacFTPWorkspace
    let repository: FTPRepository
    let coordinator: EngineerApplicationCoordinator
    @State private var pendingDelete: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Скачивания").font(.headline)
                Spacer()
                Menu("Папка сохранения") {
                    Button("Выбрать папку…") { workspace.chooseFolder(repository: repository, coordinator: coordinator) }.disabled(workspace.isBusy)
                    if repository.destinationBookmark != nil { Button("Забыть папку") { perform { try await repository.setDestinationBookmark(nil) } } }
                }
                Button("Показать папку на Mac") {
                    if let url = repository.managedDirectory() {
                        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(url) }
                        catch { workspace.error = error.localizedDescription }
                    }
                }
            }.padding(12)
            Text("Скачивание идёт, пока приложение открыто. После перезапуска прерванную передачу можно повторить; каталог проверяется перед каждым скачиванием.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            List(repository.transfers) { record in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(record.fileName, systemImage: record.item.isDirectory ? "doc.zipper" : "doc").font(.headline).lineLimit(1)
                        Spacer()
                        Text(record.stateTitle).foregroundStyle(.secondary)
                    }
                    Text(record.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(record.item.path)
                    if record.isActive {
                        if let progress = record.progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                        Text(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file) + (record.expectedBytes.map { " из " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let error = record.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                    HStack {
                        if record.isActive { Button("Отменить") { perform { try await repository.cancel(record.id) } } }
                        else if let file = repository.localFile(record.id) {
                            Button("Просмотр") { workspace.preview = MacDocumentPreviewItem(url: file, title: record.fileName, mimeType: MacFileAccess.mimeType(file)) }
                            Button("Сохранить как…") { workspace.save(record.id, repository: repository, coordinator: coordinator) }.disabled(workspace.isBusy)
                            Menu("Ещё") {
                                Button("Открыть") { NSWorkspace.shared.open(file) }
                                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                ShareLink(item: file) { Text("Поделиться…") }
                                Divider()
                                Button("Удалить файл…", role: .destructive) { pendingDelete = record.id }
                            }
                        } else { Button("Повторить") { perform { try await repository.enqueue(record.item, retrying: record.id) } }.disabled(repository.isRunning(record.id)) }
                        Spacer()
                        if !record.isActive { Button("Убрать из истории") { perform { try await repository.removeHistory(record.id) } }.help("Скачанный файл останется на Mac") }
                    }.controlSize(.small)
                }.padding(.vertical, 5)
            }.overlay { if repository.transfers.isEmpty { ContentUnavailableView("Нет скачиваний", systemImage: "arrow.down.circle") } }
        }
        .confirmationDialog("Удалить скачанный файл с Mac?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) { Button("Удалить файл", role: .destructive) { if let id = pendingDelete { perform { try await repository.deleteLocalFile(id) } }; pendingDelete = nil } }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        let captured = coordinator.context
        Task { do { guard let captured, coordinator.accepts(captured) else { throw CancellationError() }; try await action() } catch { if coordinator.context == captured, !AppErrorClassification.isCancellation(error) { workspace.error = error.localizedDescription } } }
    }
}
