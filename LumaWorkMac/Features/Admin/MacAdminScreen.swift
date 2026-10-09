import SwiftUI
import EngineerCore

struct MacAdminScreen: View {
    @Bindable var model: MacAdminWorkspace
    let container: MacSessionContainer
    private var repository: AdminRepository { container.admin }
    private var pages: [MacAdminPage] { MacAdminPage.allCases.filter { container.coordinator.session?.user.can($0.permission) == true } }
    private var page: MacAdminPage? { pages.contains(model.page) ? model.page : pages.first }
    private var authorized: Bool { container.adminAccess.accepts(model.grant) }
    var body: some View {
        Group {
            if authorized { content }
            else {
                VStack(spacing: 16) {
                    Label("Админка заблокирована", systemImage: "lock.shield").font(.title2)
                    Text("Подтвердите личность через Touch ID или пароль Mac.").foregroundStyle(.secondary)
                    if model.authenticating { ProgressView() }
                    if repository.forbidden { Text("Доступ запрещён сервером. Защищённые данные очищены.").foregroundStyle(.secondary) }
                    if let error = model.authError { Text(error).foregroundStyle(.red) }
                    Button("Подтвердить личность…") { Task { await model.authenticate(container: container) } }.disabled(model.authenticating)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { model.isVisible = true; container.admin.synchronizeSession(); if !authorized { await model.authenticate(container: container) } }
        .onDisappear { model.isVisible = false; model.lock(container: container) }
        .onChange(of: repository.accessGeneration) { _, _ in if !authorized { model.lock(container: container, cancelAuthentication: false) } }
        .onChange(of: container.coordinator.protectedContentGeneration) { _, _ in container.admin.synchronizeSession(); if !authorized { model.lock(container: container, cancelAuthentication: false) } }
        .onChange(of: container.coordinator.protectedAuthenticationGeneration) { _, _ in model.lock(container: container) }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Раздел", selection: Binding(get: { page ?? .overview }, set: { model.page = $0; model.search = "" })) {
                    ForEach(pages) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 620).disabled(repository.isSaving)
                Spacer()
                if let page {
                    if repository.loading.contains(page.permission) { ProgressView().controlSize(.small) }
                    Button("Обновить") { load(force: true) }.disabled(repository.loading.contains(page.permission) || repository.isSaving)
                }
            }.padding(12)
            Divider()
            if repository.forbidden {
                ContentUnavailableView {
                    Label("Доступ запрещён сервером", systemImage: "lock")
                } description: { Text("Защищённые данные очищены. Проверьте права и загрузите раздел заново.") } actions: {
                    Button("Проверить права") { Task { await container.coordinator.refreshSession(); container.admin.synchronizeSession(); if let page { try? await repository.load(page.permission, grant: model.grant, force: true) } } }
                }
            } else if let page {
                if repository.requiresRefresh {
                    Label("Результат операции неизвестен. Обновите данные перед следующей отправкой.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).padding(10)
                }
                if let error = repository.errors[page.permission] {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).padding(10)
                }
                switch page {
                case .overview: MacAdminOverviewView(repository: repository, grant: model.grant)
                case .audit: MacAdminAuditView(actions: repository.audit(grant: model.grant), isLoading: repository.loading.contains(.viewAuditLog))
                case .users: MacAdminUsersView(model: model, container: container)
                case .feedback: MacAdminFeedbackView(model: model, container: container)
                }
            } else {
                ContentUnavailableView("Разделы ещё не перенесены", systemImage: "wrench.and.screwdriver", description: Text("В текущем блоке доступны сводка, журнал, пользователи и обратная связь. У вашей учётной записи другие разрешения."))
            }
        }
        .task(id: page) { if let page { model.page = page; try? await repository.load(page.permission, grant: model.grant) } }
        .onChange(of: container.coordinator.session?.user) { _, _ in repository.synchronizeSession() }
        .onDisappear { model.cleanPreview() }
        .sheet(item: $model.editor) { editor in MacAdminUserEditorSheet(editor: editor, container: container, grant: model.grant) }
        .sheet(isPresented: Binding(get: { model.feedbackEditorID != nil }, set: { if !$0 { model.feedbackEditorID = nil } })) {
            if let message = repository.feedback(grant: model.grant).first(where: { $0.id == model.feedbackEditorID }) { MacAdminFeedbackEditor(message: message, container: container, grant: model.grant) }
        }
        .sheet(item: $model.preview, onDismiss: { model.cleanPreview() }) { item in MacDocumentPreview(url: item.url, title: item.title, mimeType: item.mimeType) }
    }
    private func load(force: Bool) { if let page { Task { try? await repository.load(page.permission, grant: model.grant, force: force) } } }
}

private struct MacAdminOverviewView: View {
    let repository: AdminRepository
    let grant: ProtectedAccessGrant?
    var body: some View {
        if let value = repository.overview(grant: grant) {
            Form {
                Section("API и хранилище") {
                    LabeledContent("Сервис", value: value.system.service)
                    LabeledContent("Состояние", value: value.system.status)
                    LabeledContent("Время сервера", value: value.system.serverTime?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    LabeledContent("Время работы", value: Duration.seconds(value.system.uptimeSeconds).formatted(.units(allowed: [.days, .hours, .minutes])))
                    LabeledContent("Node.js", value: value.system.nodeVersion)
                    LabeledContent("Память процесса", value: bytes(value.system.memoryResidentBytes))
                    LabeledContent("Файлы изображений", value: "\(value.storage.imageFiles)")
                    LabeledContent("Объём изображений", value: bytes(value.storage.bytes))
                }
                if let resources = value.resources {
                    Section("Ресурсы сервера") {
                        LabeledContent("CPU", value: "\(resources.cpuUsagePercent.formatted(.number.precision(.fractionLength(1))))% · \(resources.cpuCores) ядер")
                        LabeledContent("RAM", value: "\(bytes(resources.ramUsedBytes)) / \(bytes(resources.ramTotalBytes))")
                        LabeledContent("Диск", value: "\(bytes(resources.diskUsedBytes)) / \(bytes(resources.diskTotalBytes))")
                    }
                }
                Section("Показатели") {
                    LabeledContent("Пользователи / администраторы", value: "\(value.stats.users) / \(value.stats.admins)")
                    LabeledContent("Заблокированы", value: "\(value.stats.blockedUsers)")
                    LabeledContent("Активны за 7 дней", value: "\(value.stats.activeUsers7d)")
                    LabeledContent("Автомобили / каталоги", value: "\(value.stats.vehicles) / \(value.stats.vehicleCatalogs)")
                    LabeledContent("Без изображений авто / рюкзак", value: "\(value.stats.missingVehicleImages) / \(value.stats.missingBackpackImages)")
                    LabeledContent("Запросы изображений", value: "\(value.stats.pendingVehicleImages)")
                    LabeledContent("Привязки рюкзака / изображения без связей", value: "\(value.stats.backpackBindings) / \(value.stats.orphanImages)")
                }
                if let data = value.dataStorage {
                    Section("Данные приложения") {
                        LabeledContent("Всего", value: bytes(data.totalBytes)); LabeledContent("База данных", value: bytes(data.databaseBytes))
                        LabeledContent("Файлы", value: bytes(data.filesBytes)); LabeledContent("Загрузки", value: bytes(data.uploadBytes))
                        LabeledContent("Отчёты / шаблоны", value: "\(bytes(data.reportBytes)) / \(bytes(data.templateBytes))")
                        LabeledContent("Резервные копии БД", value: bytes(data.databaseBackupBytes))
                        LabeledContent("Файлы без владельца", value: bytes(data.unattributedFileBytes))
                    }
                    if data.usersVisible {
                        Section("Хранилище пользователей") {
                            ForEach(data.users) { user in
                                LabeledContent(user.displayName, value: bytes(user.totalBytes))
                            }
                        }
                    }
                }
            }.formStyle(.grouped).textSelection(.enabled)
        } else if repository.loading.contains(.viewOverview) { ProgressView("Загрузка сводки…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { ContentUnavailableView("Сводка не загружена", systemImage: "gauge.with.dots.needle.33percent") }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
private struct MacAdminAuditView: View {
    let actions: [AdminAuditAction]
    let isLoading: Bool
    var body: some View {
        if actions.isEmpty {
            if isLoading { ProgressView("Загрузка журнала…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("Журнал пуст", systemImage: "list.bullet.rectangle") }
        } else {
            Table(actions) {
                TableColumn("Дата") { Text($0.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "—") }.width(min: 140, ideal: 170)
                TableColumn("Администратор", value: \.actorEmail)
                TableColumn("Действие", value: \.action)
                TableColumn("Объект") { Text([$0.targetType, $0.targetID].compactMap { $0 }.joined(separator: ": ")) }
                TableColumn("Описание") { Text($0.summary ?? "—") }
            }.textSelection(.enabled)
        }
    }
}
