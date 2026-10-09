import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import EngineerCore

@MainActor @Observable
final class MacProfileWorkspace {
    var isPresented = false
    var initialized = false
    var tab = 0
    var base: UserProfileData?
    var draft = UserProfileData.empty
    var preferences = ProfilePreferences()
    var originalPreferences = ProfilePreferences()
    var avatar: DocumentUpload?
    var busy = false
    var error: String?
    var notice: String?
    var confirmsAvatarDeletion = false
    var profileConflict = false
    let fileAccess = MacFileAccess()
    var hasDirty: Bool { initialized && (draft != (base ?? .empty) || preferences != originalPreferences || avatar != nil) }
    func reset() { fileAccess.reset(); isPresented = false; initialized = false; tab = 0; base = nil; draft = .empty; preferences = .init(); originalPreferences = .init(); avatar = nil; busy = false; error = nil; notice = nil; confirmsAvatarDeletion = false; profileConflict = false }
}
struct MacProfileView: View {
    @Bindable var model: MacProfileWorkspace
    let container: MacSessionContainer
    let openDocuments: () -> Void
    let openFuel: () -> Void
    let openVehicles: () -> Void
    let openAnalytics: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var repository: ProfileRepository { container.profile }
    private var user: AppUser? { container.coordinator.session?.user }
    private var disabled: Bool { model.busy || repository.isSaving || container.coordinator.isAuthenticating || !model.initialized }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Профиль").font(.title2.weight(.semibold)); Spacer()
                Button("Обновить") { Task { await refresh() } }.disabled(disabled)
                Button("Готово") { Task { if await MacDraftRegistry.shared.confirm() { dismiss() } } }.keyboardShortcut(.cancelAction).disabled(model.busy || repository.isSaving)
            }
            if let error = model.error ?? repository.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
            TabView(selection: $model.tab) {
                summary.tabItem { Text("Обзор") }.tag(0)
                profileEditor.tabItem { Text("Личные данные") }.tag(1)
                cardEditor.tabItem { Text("Визитка") }.tag(2)
            }.disabled(disabled)
        }.padding(16).frame(width: 680, height: 670)
        .interactiveDismissDisabled(model.hasDirty || model.busy || repository.isSaving)
        .task(id: container.coordinator.context) { await initialize() }
        .confirmationDialog("Удалить фото профиля?", isPresented: $model.confirmsAvatarDeletion) { Button("Удалить фото", role: .destructive) { Task { await sendAvatar(delete: true) } } }
    }
    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack {
                        if let avatar = model.avatar, let image = preparedImage(avatar.data) { Image(nsImage: image).resizable().scaledToFit().frame(height: 130) }
                        else { MacRemotePhoto(url: avatarURL, store: container.images).frame(width: 150) }
                        Button("Выбрать фото…") { Task { await chooseAvatar() } }
                        if model.avatar != nil {
                            HStack { Button("Загрузить") { Task { await sendAvatar() } }; Button("Отмена") { model.avatar = nil } }
                        } else if user?.avatarUrl != nil { Button("Удалить фото…", role: .destructive) { model.confirmsAvatarDeletion = true } }
                    }.frame(width: 190)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(user?.profile?.fullName ?? user?.email ?? "").font(.title3.weight(.semibold))
                        Text(user?.profile?.jobTitle ?? "").foregroundStyle(.secondary)
                        LabeledContent("Почта", value: user?.email ?? "")
                        LabeledContent("Город", value: user?.profile?.city ?? "")
                        LabeledContent("Телефон", value: user?.profile?.personalPhone ?? "")
                        Button("Рабочие документы…", action: openDocuments)
                        Button("Топливная карта…", action: openFuel)
                        if let number = container.gsmFuel.profile?.profile.fuelCardNumber, !number.isEmpty { LabeledContent("Номер карты", value: number) }
                    }.textSelection(.enabled)
                }
                if model.preferences.vehicleSectionVisible, let profile = user?.profile {
                    GroupBox("Автомобиль") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Модель", value: profile.vehicleModel ?? "")
                            LabeledContent("Госномер", value: profile.vehiclePlate ?? "")
                            Button("Авто и обслуживание…", action: openVehicles)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                completedWork
                Toggle("Показывать автомобиль в профиле", isOn: $model.preferences.vehicleSectionVisible)
                Button("Сохранить настройки на Mac") { Task { await savePreferences() } }.disabled(model.preferences == model.originalPreferences)
            }.padding(12)
        }
    }
    private var profileEditor: some View {
        VStack {
            Form {
                Section("О вас") {
                    field("Фамилия", \.lastName); field("Имя", \.firstName); field("Отчество", \.middleName)
                    field("Должность", \.jobTitle); field("Город", \.city)
                    field("Подразделение", \.departmentTitle); field("Группа", \.departmentGroup); field("Табельный номер", \.personnelNumber)
                    field("Телефон", \.personalPhone); field("Рабочая почта", \.workEmail)
                }
                Section("Адреса маршрута") { field("Склад", \.routeWarehouseAddress); field("Дом", \.routeHomeAddress) }
            }.formStyle(.grouped)
            if model.profileConflict {
                HStack {
                    Text("На сервере есть изменения. Черновик сохранён.").font(.callout)
                    Spacer()
                    Button("Принять данные сервера") { model.base = user?.profile; model.draft = model.base ?? .empty; model.profileConflict = false; model.error = nil }
                }.padding(.horizontal, 10)
            }
            HStack { Text("Все поля необязательные").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Сохранить профиль") { Task { await saveProfile() } }.disabled(model.draft == (model.base ?? .empty) || repository.requiresRefresh || model.profileConflict) }.padding(10)
        }
    }
    private var cardEditor: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack {
                Form {
                    cardField("Фамилия", \.lastName); cardField("Имя", \.firstName); cardField("Отчество", \.middleName)
                    cardField("Должность", \.title); cardField("Подразделение", \.department)
                    cardField("Телефон", \.phone); cardField("Почта", \.email); cardField("Организация", \.organization)
                }
                Button("Сохранить визитку на Mac") { Task { await savePreferences() } }.disabled(model.preferences == model.originalPreferences)
            }
            VStack(spacing: 12) {
                if let image = qrImage { Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 210, height: 210).padding(12).background(.white).accessibilityLabel("QR-код визитки") }
                Text(model.preferences.card.fullName.isEmpty ? "Контакт" : model.preferences.card.fullName).font(.headline)
                ShareLink("Поделиться vCard", item: model.preferences.card.vCard)
            }
        }.padding(16)
    }
    private var completedWork: some View {
        let statistics = ProfileCompletedWorkStatistics(records: container.requests.records(.closed))
        return GroupBox("Выполненные работы") {
            VStack(alignment: .leading, spacing: 10) {
                if container.coordinator.simpleOneSession == nil { Text("Требуется вход в SimpleOne.").foregroundStyle(.secondary) }
                else if !container.requests.hasSnapshot(.personal(.closed)) { Text("Архив ещё не загружен.").foregroundStyle(.secondary) }
                else {
                    ForEach(statistics.categories) { category in
                        HStack { Text(category.category.title).frame(width: 120, alignment: .leading); ForEach(category.operations) { operation in Text("\(operation.title): \(category.counts[operation, default: 0])").font(.caption) } }
                    }
                }
                Button("Открыть аналитику…", action: openAnalytics)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func field(_ title: String, _ keyPath: WritableKeyPath<UserProfileData, String?>) -> some View { TextField(title, text: Binding(get: { model.draft[keyPath: keyPath] ?? "" }, set: { model.draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })) }
    private func cardField(_ title: String, _ keyPath: WritableKeyPath<VirtualCardData, String>) -> some View { TextField(title, text: Binding(get: { model.preferences.card[keyPath: keyPath] }, set: { model.preferences.card[keyPath: keyPath] = $0 })) }
    private var avatarURL: URL? { user?.avatarUrl.flatMap { URL(string: $0, relativeTo: AppConfig.configuredURL(container.config.lumaWorkAPIOrigin))?.absoluteURL } }
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(model.preferences.card.vCard.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private func preparedImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private func initialize() async {
        guard let captured = container.coordinator.context else { return }
        do { try await repository.loadPreferences(); guard container.coordinator.accepts(captured), !model.initialized else { return }; model.base = user?.profile; model.draft = model.base ?? .empty; model.preferences = repository.preferences; model.originalPreferences = repository.preferences; model.initialized = true }
        catch { show(error, captured) }
        try? await container.gsmFuel.loadGsm()
    }
    private func savePreferences() async {
        guard let captured = container.coordinator.context else { return }
        let value = model.preferences
        model.busy = true; defer { if container.coordinator.accepts(captured) { model.busy = false } }
        do { try await repository.savePreferences(value, expectedContext: captured); guard container.coordinator.accepts(captured) else { return }; model.originalPreferences = value; model.notice = "Настройки сохранены на Mac." }
        catch { show(error, captured) }
    }
    private func saveProfile() async {
        guard let captured = container.coordinator.context else { return }; model.busy = true; defer { if container.coordinator.accepts(captured) { model.busy = false } }
        do { try await repository.saveProfile(model.draft, base: model.base, expectedContext: captured); guard container.coordinator.accepts(captured) else { return }; model.base = user?.profile; model.draft = model.base ?? .empty; model.notice = "Профиль сохранён." }
        catch { show(error, captured) }
    }
    private func chooseAvatar() async {
        guard let captured = container.coordinator.context, let window = NSApp.keyWindow else { return }
        model.busy = true; defer { if container.coordinator.accepts(captured) { model.busy = false } }
        do {
            guard let selected = try await model.fileAccess.choose(collection: .work, allowedMIMETypes: ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"], maximumBytes: 8 * 1024 * 1024, window: window, valid: { container.coordinator.accepts(captured) }) else { return }
            let data = try await Task.detached(priority: .userInitiated) { try MacAvatarPreparation.jpeg(selected.data) }.value
            guard container.coordinator.accepts(captured) else { return }
            model.avatar = DocumentUpload(fileName: "avatar.jpg", mimeType: "image/jpeg", data: data)
        } catch { show(error, captured) }
    }
    private func sendAvatar(delete: Bool = false) async {
        guard let captured = container.coordinator.context else { return }; model.busy = true; defer { if container.coordinator.accepts(captured) { model.busy = false } }
        do { try await repository.avatar(data: delete ? nil : model.avatar?.data, mimeType: "image/jpeg", baseURL: user?.avatarUrl, expectedContext: captured); guard container.coordinator.accepts(captured) else { return }; model.avatar = nil; if let url = avatarURL { await container.images.load(url, force: true) }; model.notice = "Фото обновлено." }
        catch { show(error, captured) }
    }
    private func refresh() async {
        guard let captured = container.coordinator.context else { return }
        let oldBase = model.base ?? .empty, draft = model.draft
        let dirty = draft != oldBase
        model.busy = true; defer { if container.coordinator.accepts(captured) { model.busy = false } }
        do {
            try await repository.refresh(); guard container.coordinator.accepts(captured) else { return }
            let current = user?.profile ?? .empty
            model.error = nil
            if !dirty || current.requestBody == draft.requestBody {
                model.base = user?.profile; model.draft = current; model.profileConflict = false
            } else {
                // Preserve the user's form and its original concurrency base.
                model.profileConflict = current.requestBody != oldBase.requestBody
            }
            model.notice = "Профиль обновлён с сервера. Несохранённые правки сохранены в окне."
            if let url = avatarURL { await container.images.load(url, force: true) }
        }
        catch { show(error, captured) }
    }
    private func show(_ error: Error, _ context: SessionContext) { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { model.error = error.localizedDescription } }
}

private enum MacAvatarPreparation {
    static func jpeg(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { throw AppServiceError.message("Не удалось прочитать изображение.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw GsmFuelError.invalidResponse }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length >= 1024, output.length <= 8 * 1024 * 1024 else { throw AppServiceError.message("Не удалось подготовить фото от 1 КБ до 8 МБ.") }
        return output as Data
    }
}
