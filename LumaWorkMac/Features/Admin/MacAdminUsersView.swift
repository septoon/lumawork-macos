import SwiftUI
import EngineerCore

struct MacAdminUsersView: View {
    @Bindable var model: MacAdminWorkspace
    let container: MacSessionContainer
    private var repository: AdminRepository { container.admin }
    private var selected: AdminUserRecord? { repository.users(grant: model.grant).first { $0.id == model.userID } }
    private var users: [AdminUserRecord] {
        repository.users(grant: model.grant).filter { (!model.onlyBlocked || $0.effectiveIsBlocked) && (model.search.isEmpty || ($0.displayName + " " + $0.email + " " + ($0.profile?.city ?? "")).localizedCaseInsensitiveContains(model.search)) }
            .sorted { ($0.lastActiveAt ?? $0.registeredAt ?? .distantPast) > ($1.lastActiveAt ?? $1.registeredAt ?? .distantPast) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Имя, email или город", text: $model.search).textFieldStyle(.roundedBorder)
                Toggle("Заблокированные", isOn: $model.onlyBlocked).toggleStyle(.checkbox)
                if can(.notifyUsers) { Button("Уведомить об обновлении…") { model.editor = MacAdminUserEditor(action: .notify, user: nil) } }
            }.padding(12)
            HSplitView {
                List(selection: $model.userID) {
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.displayName).lineLimit(1)
                            Text(user.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(user.id)
                    }
                }.frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                Group {
                    if let user = selected {
                        Form {
                            Section("Пользователь") {
                                LabeledContent("Имя", value: user.displayName); LabeledContent("Email", value: user.email)
                                LabeledContent("Роль", value: user.role)
                                LabeledContent("Версия приложения", value: user.appVersionDisplay)
                                LabeledContent("Регистрация", value: date(user.registeredAt))
                                LabeledContent("Последняя активность", value: date(user.lastActiveAt))
                                LabeledContent("Последняя версия замечена", value: date(user.appVersionSeenAt))
                                LabeledContent("Доступ", value: user.effectiveIsBlocked ? "Заблокирован до \(date(user.blockedUntil))" : "Разрешён")
                                if user.isProtectedAdmin { Text("Защищённый администратор").foregroundStyle(.secondary) }
                            }
                            if let profile = user.profile {
                                Section("Профиль") {
                                    ForEach(profile.requestBody.keys.sorted(), id: \.self) { key in
                                        if let value = profile.requestBody[key], !value.isEmpty { LabeledContent(profileTitle(key), value: value) }
                                    }
                                }
                            }
                            if user.isAdmin {
                                Section("Разрешения") {
                                    ForEach(AdminPermission.allCases.filter { user.permissionSet.contains($0) }) { Text($0.title) }
                                }
                            }
                            Section("Действия") {
                                if can(.notifyUsers) { Button("Письмо об обновлении…") { model.editor = MacAdminUserEditor(action: .notify, user: user) } }
                                if mutable(user) {
                                    if can(.blockUsers) {
                                        Button(user.effectiveIsBlocked ? "Разблокировать…" : "Заблокировать…") { model.editor = MacAdminUserEditor(action: user.effectiveIsBlocked ? .unblock : .block, user: user) }
                                    }
                                    if can(.manageUserPermissions) { Button("Изменить роль и права…") { model.editor = MacAdminUserEditor(action: .access, user: user) } }
                                    if can(.deleteUsers) { Button("Удалить аккаунт…", role: .destructive) { model.editor = MacAdminUserEditor(action: .delete, user: user) } }
                                }
                            }.disabled(repository.isSaving || repository.requiresRefresh)
                        }.formStyle(.grouped).textSelection(.enabled)
                    } else {
                        ContentUnavailableView(users.isEmpty ? (repository.loading.contains(.viewUsers) ? "Загрузка пользователей…" : "Пользователей нет") : "Выберите пользователя", systemImage: "person.crop.circle")
                    }
                }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.userID) {
            if let id = model.userID, let context = container.coordinator.context { try? await repository.refreshUser(id: id, grant: model.grant, expectedContext: context) }
        }
    }
    private func can(_ permission: AdminPermission) -> Bool { container.coordinator.session?.user.can(permission) == true }
    private func mutable(_ user: AdminUserRecord) -> Bool { user.id != container.coordinator.session?.user.id && !user.isProtectedAdmin }
    private func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "—" }
    private func profileTitle(_ key: String) -> String {
        ["firstName": "Имя", "lastName": "Фамилия", "middleName": "Отчество", "jobTitle": "Должность", "departmentTitle": "Подразделение", "departmentGroup": "Группа", "personnelNumber": "Табельный номер", "city": "Город", "personalPhone": "Телефон", "workEmail": "Рабочий email", "vehicleModel": "Автомобиль", "vehiclePlate": "Госномер", "vehicleVin": "VIN", "vehicleSts": "СТС", "vehiclePts": "ПТС", "vehicleColor": "Цвет", "engineVolumeCm3": "Объём двигателя", "enginePowerHp": "Мощность", "initialMileageKm": "Начальный пробег", "routeWarehouseAddress": "Адрес склада", "routeHomeAddress": "Домашний адрес"][key] ?? key
    }
}

struct MacAdminUserEditorSheet: View {
    let editor: MacAdminUserEditor
    let container: MacSessionContainer
    let grant: ProtectedAccessGrant?
    @Environment(\.dismiss) private var dismiss
    @State private var until = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var isAdmin = false
    @State private var permissions: Set<AdminPermission> = []
    @State private var confirmationEmail = ""
    @State private var version = AppBuildIdentity.version
    @State private var build = AppBuildIdentity.build
    @State private var subject = ""
    @State private var message = ""
    @State private var error: String?
    @State private var saving = false
    @State private var confirmsMail = false
    private var title: String {
        switch editor.action { case .block: "Блокировка"; case .unblock: "Разблокировка"; case .access: "Роль и права"; case .delete: "Удаление аккаунта"; case .notify: "Письмо об обновлении" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving) }.padding(16)
            Divider()
            Form {
                Section { Text(editor.user?.email ?? "Пользователи с устаревшей версией").font(.headline).textSelection(.enabled) }
                switch editor.action {
                case .block:
                    DatePicker("Блокировать до", selection: $until, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                case .unblock: Text("Доступ пользователя будет восстановлен.")
                case .delete:
                    Text("Аккаунт и связанные данные будут удалены без возможности восстановления.")
                    TextField("Введите email пользователя", text: $confirmationEmail)
                case .access:
                    Toggle("Администратор", isOn: $isAdmin)
                    ForEach(AdminPermissionGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(AdminPermission.allCases.filter { $0.group == group }) { permission in
                                Toggle(permission.title, isOn: Binding(get: { permissions.contains(permission) }, set: { if $0 { permissions.insert(permission) } else { permissions.remove(permission) } })).toggleStyle(.checkbox).help(permission.detail)
                            }
                        }.disabled(!isAdmin)
                    }
                case .notify:
                    if editor.user == nil { Text("Сервер выбирает устаревшие версии без разделения по платформе. Рассылка может затронуть пользователей iOS и Mac.").foregroundStyle(.secondary) }
                    TextField("Версия", text: $version); TextField("Сборка (необязательно)", text: $build)
                    TextField("Тема", text: $subject)
                    TextField("Текст письма", text: $message, axis: .vertical).lineLimit(8...16)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(saving)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(editor.action == .delete ? "Удалить аккаунт" : editor.action == .notify ? "Отправить письмо…" : "Подтвердить") {
                    if editor.action == .notify { confirmsMail = true } else { save() }
                }.disabled(!valid || saving)
            }.padding(16)
        }.frame(width: 600, height: editor.action == .access ? 680 : 520)
        .interactiveDismissDisabled(saving || !confirmationEmail.isEmpty || !subject.isEmpty || !message.isEmpty || isAdmin != (editor.user?.isAdmin ?? false) || permissions != (editor.user?.permissionSet ?? []))
        .onAppear { isAdmin = editor.user?.isAdmin ?? false; permissions = editor.user?.permissionSet ?? [] }
        .confirmationDialog("Отправить письмо: \(editor.user?.email ?? "всем пользователям с устаревшей версией")? Версия \(version), сборка \(build.isEmpty ? "не указана" : build).", isPresented: $confirmsMail) { Button("Отправить") { save() } }
        .overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }
    }
    private var valid: Bool {
        switch editor.action {
        case .delete: confirmationEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == editor.user?.email.lowercased()
        case .notify: version.range(of: #"^\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil && version.count <= 40 && (build.isEmpty || (build.count <= 12 && build.allSatisfy(\.isNumber))) && (1...180).contains(subject.trimmingCharacters(in: .whitespacesAndNewlines).count) && (1...20000).contains(message.trimmingCharacters(in: .whitespacesAndNewlines).count)
        case .block: until > Date()
        default: true
        }
    }
    private func save() {
        guard !saving, valid, let context = container.coordinator.context else { return }
        let generation = container.admin.accessGeneration; saving = true; error = nil
        Task {
            defer { if container.coordinator.accepts(context), container.admin.accessGeneration == generation { saving = false } }
            do {
                switch editor.action {
                case .block: if let user = editor.user { try await container.admin.block(user, until: until, grant: grant, expectedContext: context) }
                case .unblock: if let user = editor.user { try await container.admin.block(user, until: nil, grant: grant, expectedContext: context) }
                case .access: if let user = editor.user { try await container.admin.access(user, isAdmin: isAdmin, permissions: isAdmin ? permissions : [], grant: grant, expectedContext: context) }
                case .delete: if let user = editor.user { try await container.admin.delete(user, confirmationEmail: confirmationEmail, grant: grant, expectedContext: context) }
                case .notify:
                    let result = try await container.admin.notify(userID: editor.user?.id, version: version, build: build.isEmpty ? nil : build, subject: subject, body: message, grant: grant, expectedContext: context)
                    if let result { container.notices.show("Подобрано: \(result.matched), отправлено: \(result.sent), ошибок: \(result.failed).") }
                }
                guard container.coordinator.accepts(context), container.admin.accessGeneration == generation else { return }; dismiss()
            } catch { if container.coordinator.accepts(context), container.admin.accessGeneration == generation, !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
