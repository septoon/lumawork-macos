import SwiftUI
import AppKit
import EngineerCore

@MainActor @Observable final class MacWikiWorkspace {
    var query = "инструкция"
    var selection: String?
    var showsCredentials = false
    var tokenDraft = ""
    var preview: MacDocumentPreviewItem?
    var isBusy = false
    var attemptedSearch = false
    var attemptedArticle = false
    let fileAccess = MacFileAccess()
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var directory: URL?
    func clearPreview() { preview = nil; if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil }
    func reset() { operation = UUID(); task?.cancel(); task = nil; fileAccess.reset(); clearPreview(); isBusy = false; tokenDraft = ""; showsCredentials = false; selection = nil; query = "инструкция"; attemptedSearch = false; attemptedArticle = false }
    func close() { operation = UUID(); task?.cancel(); task = nil; fileAccess.reset(); clearPreview(); tokenDraft = ""; isBusy = false }
    func pdf(id: String, title: String, saving: Bool, container: MacSessionContainer) {
        guard !isBusy, let context = container.coordinator.context, let window = NSApp.keyWindow else { return }
        let captured = UUID(); operation = captured; isBusy = true
        task = Task {
            defer { if operation == captured { isBusy = false; task = nil } }
            var downloaded: URL?
            do {
                guard operation == captured, container.coordinator.accepts(context), window.isVisible else { throw CancellationError() }
                let file = try await container.wiki.downloadPDF(id); downloaded = file
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard operation == captured, container.coordinator.accepts(context), window.isVisible else { throw CancellationError() }
                let name = (title as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-") + ".pdf"
                if saving {
                    _ = try await fileAccess.save(file: file, name: name, window: window, valid: { self.operation == captured && container.coordinator.accepts(context) })
                } else {
                    clearPreview()
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineerMac-WikiPreviews", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let destination = root.appendingPathComponent("article.pdf")
                    try FileManager.default.moveItem(at: file, to: destination)
                    directory = root; preview = MacDocumentPreviewItem(url: destination, title: title, mimeType: "application/pdf")
                }
            } catch {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
                if operation == captured, container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) }
            }
        }
    }
}

struct MacWikiScreen: View {
    @Bindable var model: MacWikiWorkspace
    let container: MacSessionContainer
    @Environment(\.dismiss) private var dismiss
    @State private var configurationRevision = UUID()
    private var repository: WikiRepository { container.wiki }
    private var query: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var configured: Bool { !(container.config.wikiAPIOrigin ?? "").isEmpty && !((try? container.wikiToken()) ?? "").isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Wiki", systemImage: "books.vertical").font(.headline)
                if let updated = updateDate { Text("Обновлено: " + updated).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Доступ к Wiki") { model.tokenDraft = ""; model.showsCredentials = true }
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if !configured || repository.authorizationRequired {
                ContentUnavailableView("Нужен доступ к Wiki", systemImage: "lock", description: Text("Укажите токен Wiki для этой учётной записи. Адрес сервиса задаётся в локальной конфигурации приложения."))
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            TextField("Поиск в Wiki", text: $model.query).textFieldStyle(.roundedBorder).onSubmit { search(force: true) }
                            Button { search(force: true) } label: { Label("Обновить", systemImage: "arrow.clockwise") }.labelStyle(.iconOnly).disabled(repository.isLoading("search:" + query))
                        }.padding(10)
                        List(selection: $model.selection) {
                            ForEach(repository.search(query)?.results ?? []) { result in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.title).font(.headline)
                                    Text(result.section).font(.caption).foregroundStyle(.secondary)
                                    Text(result.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }.padding(.vertical, 5).tag(result.id)
                            }
                        }
                        if repository.isLoading("search:" + query) { ProgressView().controlSize(.small).padding(8) }
                        else if query.isEmpty { Text("Введите запрос").foregroundStyle(.secondary).padding() }
                        else if let page = repository.search(query), page.results.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary).padding() }
                        else if model.attemptedSearch, repository.search(query) == nil { Text("Поиск недоступен. Повторите запрос.").foregroundStyle(.secondary).padding() }
                    }.frame(minWidth: 230, idealWidth: 300, maxWidth: 400)
                    article.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let warning = repository.cacheWarning { Text(warning).font(.caption).foregroundStyle(.secondary).padding(8) }
        }.frame(minWidth: 850, idealWidth: 1050, minHeight: 580, idealHeight: 750)
        .overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }
        .task(id: query + configurationRevision.uuidString + (repository.catalogVersion ?? "")) {
            guard configured else { return }; let captured = container.coordinator.context
            model.attemptedSearch = false
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); try await repository.loadSearch(query) } catch {}
            if !Task.isCancelled, container.coordinator.context == captured { model.attemptedSearch = true }
        }
        .task { if configured { try? await repository.loadHealth(force: true) } }
        .task(id: (model.selection ?? "") + (repository.catalogVersion ?? "") + configurationRevision.uuidString) {
            guard configured, let id = model.selection else { return }; let captured = container.coordinator.context
            model.attemptedArticle = false
            try? await repository.loadArticle(id)
            if !Task.isCancelled, container.coordinator.context == captured, model.selection == id { model.attemptedArticle = true }
        }
        .sheet(isPresented: $model.showsCredentials) { credentials }
        .sheet(item: $model.preview, onDismiss: { model.clearPreview() }) { item in MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) }
        .onDisappear { model.close() }
    }
    @ViewBuilder private var article: some View {
        if let id = model.selection {
            if let article = repository.article(id) {
                let document = WikiArticleDocument(article: article)
                VStack(spacing: 0) {
                    HStack {
                        Text(document.section).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if article.hasPdf == true || repository.search(query)?.results.first(where: { $0.id == id })?.hasPdf == true {
                            Button("Открыть PDF") { model.pdf(id: id, title: document.title, saving: false, container: container) }.disabled(model.isBusy)
                            Button("Сохранить PDF…") { model.pdf(id: id, title: document.title, saving: true, container: container) }.disabled(model.isBusy)
                        } else {
                            // Older Wiki catalogs omit hasPdf. Download remains an explicit action.
                            Button("Открыть PDF") { model.pdf(id: id, title: document.title, saving: false, container: container) }.disabled(model.isBusy)
                        }
                        if model.isBusy || repository.isLoading("article:" + id) { ProgressView().controlSize(.small) }
                    }.padding(12)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(document.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            if let date = document.convertedAt { Text("Дата конвертации: " + date).font(.caption).foregroundStyle(.secondary) }
                            if let url = URL(string: document.sourceURL), MacSafeExternalURL.permits(url) { Link("Источник статьи", destination: url).font(.caption) }
                            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                                switch block {
                                case .heading(let level, let title): Text(title).font(level == 2 ? .title3.weight(.semibold) : .headline).textSelection(.enabled)
                                case .paragraph(let text, let important): Text(text).textSelection(.enabled).fontWeight(important ? .semibold : .regular)
                                case .bullets(let items): ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top) { Text("•"); Text(item).textSelection(.enabled) } }
                                case .image(let title, _): Label(title + " — изображение доступно в PDF", systemImage: "photo").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            if article.truncated == true { Text("Текст статьи сокращён сервером.").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: 800, alignment: .leading).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if repository.isLoading("article:" + id) { ProgressView("Загрузка статьи…") }
            else if model.attemptedArticle { ContentUnavailableView("Статья недоступна", systemImage: "doc", description: Text("Повторите загрузку.")); Button("Повторить") { Task { try? await repository.loadArticle(id, force: true) } } }
            else { ProgressView() }
        } else { ContentUnavailableView("Выберите статью", systemImage: "doc.text.magnifyingglass") }
    }
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Доступ к Wiki").font(.headline)
            Text("Токен хранится в Keychain отдельно для вашей учётной записи.").foregroundStyle(.secondary)
            SecureField("Токен Wiki", text: $model.tokenDraft).textFieldStyle(.roundedBorder)
            HStack {
                Button("Отмена") { model.tokenDraft = ""; model.showsCredentials = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить") {
                    guard let context = container.coordinator.context else { return }
                    do { try container.saveWikiToken(model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines), context: context); model.tokenDraft = ""; model.showsCredentials = false; configurationRevision = UUID(); Task { try? await repository.loadHealth(force: true) } }
                    catch { container.notices.show(error.localizedDescription) }
                }.disabled(model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 430).overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }.onDisappear { model.tokenDraft = "" }
    }
    private func search(force: Bool) { let query = query; Task { try? await repository.loadSearch(query, force: force) } }
    private var updateDate: String? {
        guard let snapshot = repository.catalogVersion ?? repository.search(query)?.snapshotID,
              snapshot.range(of: #"^\d{8}T\d{6}Z$"#, options: .regularExpression) != nil else { return nil }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; parser.isLenient = false
        guard let date = parser.date(from: snapshot), parser.string(from: date) == snapshot else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "dd.MM.yyyy HH:mm"; return formatter.string(from: date)
    }
}
