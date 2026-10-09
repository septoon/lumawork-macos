import SwiftUI
import AppKit
import EngineerCore

@MainActor @Observable
final class MacFTPWorkspace {
    var path = "/"
    var selection: String?
    var search = ""
    var showsTransfers = false
    var preview: MacDocumentPreviewItem?
    var error: String?
    var notice: String?
    var isBusy = false
    var isPresented = false
    let fileAccess = MacFileAccess()
    private var operation: UUID?
    private var task: Task<Void, Never>?
    func reset() { operation = nil; task?.cancel(); task = nil; fileAccess.reset(); path = "/"; selection = nil; search = ""; showsTransfers = false; preview = nil; error = nil; notice = nil; isBusy = false; isPresented = false }
    func chooseFolder(repository: FTPRepository, coordinator: EngineerApplicationCoordinator) {
        guard !isBusy, let captured = coordinator.context, let window = NSApp.keyWindow else { return }
        let id = UUID(); operation = id; isBusy = true; error = nil
        task = Task {
            defer { if self.operation == id { self.isBusy = false; self.operation = nil; self.task = nil } }
            do {
                let bookmark = try await fileAccess.chooseFolder(window: window, valid: { self.operation == id && self.isPresented && coordinator.accepts(captured) })
                guard self.operation == id, coordinator.accepts(captured) else { throw CancellationError() }
                if let bookmark { try await repository.setDestinationBookmark(bookmark); if self.operation == id, coordinator.accepts(captured) { self.notice = "Папка сохранения запомнена для этого аккаунта." } }
            } catch { if self.operation == id, coordinator.accepts(captured), !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    func save(_ id: UUID, repository: FTPRepository, coordinator: EngineerApplicationCoordinator) {
        guard !isBusy, let captured = coordinator.context, let window = NSApp.keyWindow, let file = repository.localFile(id) else { return }
        let operation = UUID(); self.operation = operation; isBusy = true; error = nil; notice = nil
        task = Task {
            defer { if self.operation == operation { self.isBusy = false; self.operation = nil; self.task = nil } }
            do {
                if try await fileAccess.save(file: file, name: file.lastPathComponent, bookmark: repository.destinationBookmark, window: window, valid: { self.operation == operation && self.isPresented && coordinator.accepts(captured) && repository.localFile(id) == file }) { notice = "Файл сохранён." }
            } catch { if self.operation == operation, coordinator.accepts(captured), !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
struct MacFTPScreen: View {
    @Bindable var workspace: MacFTPWorkspace
    let repository: FTPRepository
    let coordinator: EngineerApplicationCoordinator
    private var rows: [FTPItem] { repository.items(workspace.path).filter { workspace.search.isEmpty || $0.name.localizedCaseInsensitiveContains(workspace.search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Раздел FTP", selection: $workspace.showsTransfers) { Text("Файлы FTP").tag(false); Text("Скачивания (\(repository.transfers.filter(\.isActive).count))").tag(true) }.pickerStyle(.segmented).frame(width: 340)
                Spacer()
                Button { Task { try? await repository.load(workspace.path, force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить каталог").disabled(repository.isLoading(workspace.path))
            }.padding(12)
            Divider()
            if workspace.showsTransfers { MacTransferQueueView(workspace: workspace, repository: repository, coordinator: coordinator) }
            else {
                HSplitView {
                    List {
                        Section("Каталоги") { Button { navigate("/") } label: { Label("Корень FTP", systemImage: "externaldrive.connected.to.line.below") }.buttonStyle(.plain) }
                        Section("Избранное") {
                            ForEach(repository.favorites.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                                Button { navigate(path) } label: { Label((path as NSString).lastPathComponent, systemImage: "folder").help(path) }.buttonStyle(.plain)
                                    .contextMenu { Button("Убрать из избранного") { toggleFavorite(path) } }
                            }
                        }
                    }.listStyle(.sidebar).frame(minWidth: 160, idealWidth: 210, maxWidth: 280)
                    VStack(spacing: 0) {
                        HStack {
                            Button { navigate((workspace.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "chevron.up") }.help("На уровень вверх").disabled(workspace.path == "/")
                            ScrollView(.horizontal) {
                                HStack(spacing: 5) {
                                    Button("FTP") { navigate("/") }
                                    ForEach(breadcrumbs, id: \.self) { path in Image(systemName: "chevron.right").foregroundStyle(.tertiary); Button((path as NSString).lastPathComponent) { navigate(path) } }
                                }.buttonStyle(.plain).lineLimit(1)
                            }
                            Button { toggleFavorite(workspace.path) } label: { Image(systemName: repository.favorites.contains(workspace.path) ? "star.fill" : "star") }.help("Избранное").disabled(workspace.path == "/")
                            TextField("Поиск в папке", text: $workspace.search).frame(width: 200)
                        }.padding(10)
                        Table(rows, selection: $workspace.selection) {
                            TableColumn("Название") { Label($0.name, systemImage: $0.isDirectory ? "folder" : "doc") }
                            TableColumn("Размер") { Text($0.sizeText ?? $0.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—") }.width(100)
                            TableColumn("Изменён") { Text($0.modifiedAt ?? "—") }.width(min: 130, ideal: 160)
                        }.contextMenu(forSelectionType: String.self) { ids in if let item = rows.first(where: { ids.contains($0.id) }) { itemActions(item) } } primaryAction: { ids in if let item = rows.first(where: { ids.contains($0.id) }) { if item.isDirectory { navigate(item.path) } else { download(item) } } }
                        .overlay { if rows.isEmpty { if repository.isLoading(workspace.path) && !repository.hasSnapshot(workspace.path) { ProgressView("Загрузка каталога…") } else if !repository.hasSnapshot(workspace.path), let error = repository.errors[workspace.path] { ContentUnavailableView("Каталог недоступен", systemImage: "exclamationmark.triangle", description: Text(error)) } else { ContentUnavailableView(workspace.search.isEmpty ? "Папка пуста" : "Ничего не найдено", systemImage: "folder") } } }
                        HStack { if let item = rows.first(where: { $0.id == workspace.selection }) { itemActions(item) }; Spacer(); Text("\(rows.count) элементов").foregroundStyle(.secondary) }.padding(10)
                    }
                }
            }
            if repository.offlinePaths.contains(workspace.path) { Label("Показан локальный каталог", systemImage: "wifi.slash").foregroundStyle(.secondary).padding(8) }
            if let error = workspace.error ?? repository.errors[workspace.path] ?? repository.cacheWarning { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            if let notice = workspace.notice { Text(notice).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: workspace.path) { workspace.isPresented = true; try? await repository.load(workspace.path) }
        .onDisappear { workspace.isPresented = false; workspace.fileAccess.reset(); workspace.preview = nil }
        .sheet(item: $workspace.preview) { item in MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) }
    }
    private var breadcrumbs: [String] { let components = workspace.path.split(separator: "/"); return components.indices.map { "/" + components[...$0].joined(separator: "/") } }
    private func navigate(_ path: String) { workspace.path = path.isEmpty ? "/" : path; workspace.selection = nil; workspace.search = ""; workspace.error = nil }
    private func toggleFavorite(_ path: String) { let captured = coordinator.context; Task { do { guard let captured, coordinator.accepts(captured) else { throw CancellationError() }; try await repository.toggleFavorite(path) } catch { if coordinator.context == captured { workspace.error = error.localizedDescription } } } }
    private func download(_ item: FTPItem) {
        let captured = coordinator.context
        Task { do { guard let captured, coordinator.accepts(captured) else { throw CancellationError() }; try await repository.enqueue(item); if coordinator.context == captured { workspace.showsTransfers = true; workspace.notice = "Скачивание продолжается, пока приложение открыто." } } catch { if coordinator.context == captured { workspace.error = error.localizedDescription } } }
    }
    @ViewBuilder private func itemActions(_ item: FTPItem) -> some View {
        if item.isDirectory { Button("Открыть") { navigate(item.path) }; Button(repository.favorites.contains(item.path) ? "Убрать из избранного" : "В избранное") { toggleFavorite(item.path) } }
        Button("Скопировать путь") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string) }
        Button(item.isDirectory ? "Скачать ZIP…" : "Скачать…") { download(item) }.disabled(repository.transfers.contains(where: { $0.item.path == item.path && $0.isActive }))
    }
}
