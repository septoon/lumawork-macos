import SwiftUI
import EngineerCore

@MainActor @Observable
final class MacEquipmentWorkspace {
    var office = false
    var search = ""
    var selection: String?
    var photoRevision = 0
    var error: String?
    func reset() { office = false; search = ""; selection = nil; photoRevision = 0; error = nil }
}
struct MacEquipmentScreen: View {
    @Bindable var model: MacEquipmentWorkspace
    let container: MacSessionContainer
    let openAccount: () -> Void
    private var backpack: [BackpackItem] { (container.backpack.value("all") ?? []).filter { model.search.isEmpty || [$0.name, $0.serialNumber, $0.responsible].joined(separator: " ").localizedStandardContains(model.search) } }
    private var office: [OfficeEquipmentItem] { (container.equipment.value("all") ?? []).filter { model.search.isEmpty || [$0.displayName, $0.serialNumber, $0.vendor, $0.model, $0.number, $0.receivedAt].joined(separator: " ").localizedStandardContains(model.search) } }
    private var loading: Bool { model.office ? container.equipment.isLoading("all") : container.backpack.isLoading("all") }
    private var error: String? { model.error ?? (model.office ? container.equipment.errors["all"] : container.backpack.errors["all"]) }
    private var photos: [EquipmentPhoto] { container.equipmentPhotos.value(model.office ? "office" : "backpack") ?? EquipmentPhotoService(config: container.config).fallback(office: model.office) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Оборудование", selection: $model.office) { Text("ЗИП").tag(false); Text("Личное оборудование").tag(true) }.pickerStyle(.segmented).frame(width: 330)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { model.photoRevision += 1; Task { await container.loadEquipment(office: model.office, force: true) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(loading)
            }.padding(12)
            if container.coordinator.simpleOneSession == nil {
                ContentUnavailableView { Label("Требуется вход в SimpleOne", systemImage: "person.crop.circle.badge.exclamationmark") } actions: { Button("Учётная запись", action: openAccount) }
            } else {
                if model.office ? container.equipment.offline.contains("all") : container.backpack.offline.contains("all") { Label("Нет связи. Показаны сохранённые данные.", systemImage: "wifi.slash").font(.callout).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8) }
                if let warning = model.office ? container.equipment.cacheWarning : container.backpack.cacheWarning { Text(warning).foregroundStyle(.secondary).font(.callout) }
                if model.office { officeTable } else { backpackTable }
            }
        }
        .searchable(text: $model.search, prompt: "Название, серийный номер")
        .task(id: "\(container.coordinator.context?.epoch ?? 0)|\(model.office)") { await container.loadEquipment(office: model.office) }
        .onChange(of: model.office) { _, _ in model.selection = nil; model.search = "" }
        .inspector(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) { inspector.padding(16).inspectorColumnWidth(min: 280, ideal: 330, max: 460) }
    }
    private var officeTable: some View {
        Table(office, selection: $model.selection) {
            TableColumn("Наименование", value: \.displayName)
            TableColumn("Серийный номер", value: \.serialNumber)
            TableColumn("Получено", value: \.receivedAt)
        }.overlay { if office.isEmpty { emptyState(loaded: container.equipment.value("all") != nil, title: "Нет личного оборудования", image: "desktopcomputer") } }
    }
    private var backpackTable: some View {
        Table(backpack, selection: $model.selection) {
            TableColumn("Наименование", value: \.name)
            TableColumn("Серийный номер", value: \.serialNumber)
            TableColumn("Кол-во") { Text("\($0.quantity)") }.width(60)
            TableColumn("Место") { Text(location($0).title) }.width(100)
            TableColumn("Получено", value: \.receivedAt)
        }.overlay { if backpack.isEmpty { emptyState(loaded: container.backpack.value("all") != nil, title: "ЗИП отсутствует", image: "backpack") } }
    }
    @ViewBuilder private func emptyState(loaded: Bool, title: String, image: String) -> some View {
        if !loaded, loading { ProgressView("Загрузка оборудования…") }
        else if !loaded, error != nil { ContentUnavailableView("Не удалось загрузить оборудование", systemImage: "exclamationmark.triangle") }
        else { ContentUnavailableView(model.search.isEmpty ? title : "Ничего не найдено", systemImage: image) }
    }
    @ViewBuilder private var inspector: some View {
        ScrollView {
            if model.office, let item = office.first(where: { $0.id == model.selection }) {
                VStack(alignment: .leading, spacing: 12) {
                    MacRemotePhoto(url: EquipmentPhotoCatalog.match(for: item.photoCandidateNames, in: photos)?.url, store: container.images, revision: model.photoRevision)
                    Text(item.displayName).font(.headline)
                    LabeledContent("Серийный номер", value: item.serialNumber)
                    LabeledContent("Получено", value: item.receivedAt)
                    ForEach(item.detailSections) { section in
                        Divider(); Text(section.title).font(.headline)
                        ForEach(section.fields) { field in VStack(alignment: .leading) { Text(field.title).font(.caption).foregroundStyle(.secondary); Text(field.value).textSelection(.enabled) } }
                    }
                }
            } else if let item = backpack.first(where: { $0.id == model.selection }) {
                VStack(alignment: .leading, spacing: 12) {
                    MacRemotePhoto(url: EquipmentPhotoCatalog.match(for: item.name, in: photos)?.url, store: container.images, revision: model.photoRevision)
                    Text(item.name).font(.headline)
                    LabeledContent("Серийный номер", value: item.serialNumber)
                    LabeledContent("Ответственный", value: item.responsible)
                    LabeledContent("Получено", value: item.receivedAt)
                    LabeledContent("Количество", value: String(item.quantity))
                    Picker("Место", selection: Binding(get: { location(item) }, set: { setLocation($0, item: item) })) { ForEach(BackpackItemLocation.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("Место сохраняется на этом Mac для текущего пользователя SimpleOne.").font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled)
            }
        }
    }
    private func location(_ item: BackpackItem) -> BackpackItemLocation {
        if let saved = container.locations.value("saved")?[BackpackItemLocation.storageIdentity(for: item)] { return saved }
        let serial = item.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let inCar = !serial.isEmpty && container.requests.records(.returnEquipment).contains { CoordinationPolicy.returnEquipmentSerial($0).compare(serial, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return inCar ? .car : .warehouse
    }
    private func setLocation(_ location: BackpackItemLocation, item: BackpackItem) {
        guard let captured = container.coordinator.context else { return }
        Task {
            do { try await container.locations.loadLocal("saved"); var values = container.locations.value("saved") ?? [:]; values[BackpackItemLocation.storageIdentity(for: item)] = location; try await container.locations.setLocal(values, key: "saved", expectedContext: captured) }
            catch { if container.coordinator.accepts(captured), !AppErrorClassification.isCancellation(error) { model.error = error.localizedDescription } }
        }
    }
}
