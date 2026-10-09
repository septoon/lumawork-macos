import SwiftUI
import EngineerCore

private struct MaintenanceTableRow: Identifiable { let record: MaintenanceRecord; var id: String { record.stableID } }
struct MacVehiclesScreen: View {
    @Bindable var workspace: MacVehiclesWorkspace
    let repository: VehicleMaintenanceRepository
    let documents: DocumentsRepository
    let coordinator: EngineerApplicationCoordinator
    let profileChanged: () -> Void
    @State private var pendingDelete: MaintenanceRecord?
    private var selected: Vehicle? { repository.vehicles.first { $0.id == workspace.selection } }
    private var rows: [MaintenanceRecord] {
        guard let selected else { return [] }
        return repository.maintenance.filter { record in
            (record.vehicleID == selected.id || record.vehicleID == nil && repository.vehicles.count == 1) &&
            (workspace.search.isEmpty || record.procedure.localizedCaseInsensitiveContains(workspace.search) || record.date.contains(workspace.search))
        }.sorted { $0.date > $1.date }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Автомобили и обслуживание").font(.headline)
                Spacer()
                if repository.isLoading { ProgressView().controlSize(.small) }
                Button("Добавить авто…") { editVehicle(nil) }.disabled(repository.isSaving || repository.requiresRefresh)
                Button { Task { try? await repository.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить автомобили и обслуживание").disabled(repository.isSaving || repository.isLoading)
            }.padding(12)
            Divider()
            HSplitView {
                List(selection: $workspace.selection) {
                    ForEach(repository.vehicles) { vehicle in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.displayName).fontWeight(vehicle.isPrimary ? .semibold : .regular)
                            Text(vehicle.licensePlate ?? "Госномер не указан").font(.caption).foregroundStyle(.secondary)
                        }.tag(vehicle.id)
                    }
                }.listStyle(.sidebar).frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
                if let selected {
                    VStack(alignment: .leading, spacing: 12) {
                        vehicleInfo(selected)
                        HStack {
                            Text("Обслуживание").font(.headline)
                            TextField("Поиск", text: $workspace.search).frame(maxWidth: 180)
                            Spacer()
                            Button("Добавить…") { editMaintenance(nil) }.disabled(repository.isSaving || repository.requiresRefresh)
                        }
                        Table(rows.map { MaintenanceTableRow(record: $0) }, selection: $workspace.maintenanceSelection) {
                            TableColumn("Дата") { Text($0.record.date) }.width(90)
                            TableColumn("Процедура") { Text($0.record.procedure) }
                            TableColumn("Пробег, км") { Text(String($0.record.mileage)) }.width(100)
                            TableColumn("Запчасти, ₽") { Text(GsmFuelFormatting.number($0.record.parts.reduce(0) { $0 + $1.cost })) }.width(105)
                            TableColumn("Работа, ₽") { Text($0.record.workCost.map(GsmFuelFormatting.number) ?? "—") }.width(100)
                            TableColumn("Всего, ₽") { Text($0.record.totalCost.map(GsmFuelFormatting.number) ?? "—") }.width(100)
                        }.contextMenu(forSelectionType: String.self) { ids in
                            if let record = rows.first(where: { ids.contains($0.stableID) }) {
                                Button("Изменить…") { editMaintenance(record) }
                                Button("Удалить…", role: .destructive) { pendingDelete = record }.disabled(record.id == nil || repository.isSaving)
                            }
                        } primaryAction: { ids in if let record = rows.first(where: { ids.contains($0.stableID) }) { editMaintenance(record) } }
                        .overlay { if rows.isEmpty { ContentUnavailableView("Нет записей обслуживания", systemImage: "wrench.and.screwdriver") } }
                        HStack {
                            Button("Изменить…") { if let record = rows.first(where: { $0.stableID == workspace.maintenanceSelection }) { editMaintenance(record) } }.disabled(workspace.maintenanceSelection == nil || repository.isSaving || repository.requiresRefresh)
                            Spacer()
                            Text("\(rows.count) записей").foregroundStyle(.secondary)
                        }
                    }.padding(14).frame(minWidth: 580)
                } else if repository.isLoading && !repository.hasSnapshot { ProgressView("Загрузка авто…").frame(maxWidth: .infinity) }
                else { ContentUnavailableView("Выберите автомобиль", systemImage: "car", description: Text("Добавьте автомобиль, чтобы вести обслуживание.")) }
            }
            if repository.connection == .offline { Label("Локальные данные авто и обслуживания", systemImage: "wifi.slash").foregroundStyle(.secondary).padding(10) }
            if let error = workspace.error ?? repository.error ?? repository.cacheWarning { Text(error).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            if let notice = workspace.notice { Text(notice).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .sheet(isPresented: $workspace.documents.isPresented, onDismiss: { Task { try? await repository.load(force: true) } }) { if let selected { MacDocumentsView(model: workspace.documents, collection: .vehicle(selected.id), repository: documents, coordinator: coordinator) } }
        .sheet(item: $workspace.vehicleEditor) { model in MacVehicleEditor(model: model, repository: repository, coordinator: coordinator) { saved in workspace.vehicleEditor = nil; if let saved { workspace.selection = saved.id; profileChanged() } } }
        .sheet(item: $workspace.maintenanceEditor) { model in MacMaintenanceEditor(model: model, vehicles: repository.vehicles, repository: repository, coordinator: coordinator) { workspace.maintenanceEditor = nil } }
        .confirmationDialog("Удалить запись обслуживания с сервера?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) { if let base = pendingDelete, let context = coordinator.context {
                Task { do { try await repository.deleteMaintenance(base, expectedContext: context) } catch { if coordinator.accepts(context) { workspace.error = repository.error ?? error.localizedDescription } } }
            }; pendingDelete = nil }
        }
        .task(id: coordinator.context) { try? await repository.load(); reconcileSelection() }
        .onChange(of: repository.vehicles) { _, _ in reconcileSelection() }
        .onChange(of: workspace.selection) { _, _ in workspace.maintenanceSelection = nil }
    }
    private func reconcileSelection() { if !repository.vehicles.contains(where: { $0.id == workspace.selection }) { workspace.selection = (repository.vehicles.first(where: \.isPrimary) ?? repository.vehicles.first)?.id } }
    private func editVehicle(_ base: Vehicle?) {
        guard !repository.isSaving, let context = coordinator.context else { return }
        workspace.vehicleEditor = MacVehicleEditorModel(base: base, profile: base?.isPrimary == true || repository.vehicles.isEmpty ? coordinator.session?.user.profile : nil, context: context)
    }
    private func editMaintenance(_ base: MaintenanceRecord?) {
        guard !repository.isSaving, let context = coordinator.context else { return }
        workspace.maintenanceEditor = MacMaintenanceEditorModel(base: base, vehicleID: selected?.id, context: context)
    }
    private func vehicleInfo(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(vehicle.displayName).font(.title2); if vehicle.isPrimary { Text("Основной").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Документы…") { workspace.documents.isPresented = true }; Button("Изменить авто…") { editVehicle(vehicle) }.disabled(repository.isSaving || repository.requiresRefresh) }
            Text([vehicle.modelLine, vehicle.year.map(String.init), vehicle.licensePlate, vehicle.colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                GridRow { Text("VIN"); Text(vehicle.vin ?? "—"); Text("Пробег"); Text(vehicle.currentMileageKm.map { "\($0) км" } ?? "—") }
                GridRow { Text("СТС"); Text(vehicle.sts ?? "—"); Text("ПТС"); Text(vehicle.pts ?? "—") }
                GridRow { Text("Двигатель"); Text(vehicle.engineVolumeCm3.map { "\($0) см³" } ?? "—"); Text("Мощность"); Text(vehicle.enginePowerHp.map { "\($0) л. с." } ?? "—") }
            }.font(.callout).textSelection(.enabled)
            Divider()
        }
    }
}
