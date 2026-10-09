import SwiftUI
import EngineerCore

struct MacFuelScreen: View {
    @Bindable var workspace: MacFuelWorkspace
    let repository: GsmFuelRepository
    let vehicles: VehicleMaintenanceRepository
    let routes: RouteDayRepository
    let coordinator: EngineerApplicationCoordinator
    let archiveOwnerEmail: String?
    @State private var pendingDelete: FuelRecord?
    @State private var confirmsMileage = false
    @State private var isSynchronizing = false
    private var month: String { String(MacRouteDate.key(workspace.selectedDate).prefix(7)) }
    private var canArchive: Bool { FuelArchivePolicy.isAvailable(userEmail: coordinator.session?.user.email ?? "", ownerEmail: archiveOwnerEmail) }
    private var baseRecords: [FuelRecord] { repository.records.filter { canArchive && workspace.showsArchive ? !FuelArchivePolicy.isCurrent($0) : FuelArchivePolicy.isCurrent($0) } }
    private var rows: [FuelRecord] {
        baseRecords.filter {
            let recordMonth = $0.recordType == .adjustment ? $0.monthKey ?? String($0.date.prefix(7)) : String($0.date.prefix(7))
            let query = workspace.search.trimmingCharacters(in: .whitespacesAndNewlines)
            return recordMonth == month && (query.isEmpty || [$0.date, $0.comment ?? "", $0.fuelType ?? "", title($0)].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }.sorted { ($0.date, $0.stableID) > ($1.date, $1.stableID) }
    }
    private var selection: FuelRecord? { rows.first { $0.stableID == workspace.selection } }
    private var summary: FuelSummaryMonth? { FuelSummaryCalculator.build(records: baseRecords).monthly.first { $0.key == month } }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            if let summary { monthSummary(summary).padding(12); Divider() }
            Table(rows.map(FuelTableRow.init), selection: $workspace.selection) {
                TableColumn("Дата") { Text($0.record.date) }.width(95)
                TableColumn("Запись") { Text(title($0.record)) }.width(min: 110, ideal: 150)
                TableColumn("Пробег, км") { Text(number($0.record.mileage)) }.width(90)
                TableColumn("Литры") { Text(number($0.record.liters)) }.width(70)
                TableColumn("Сумма, ₽") { Text(number($0.record.recordType == .fuel ? $0.record.fuelCost : $0.record.amount)) }.width(90)
                TableColumn("Топливо") { Text($0.record.fuelType ?? "—") }.width(100)
                TableColumn("Комментарий") { Text($0.record.comment ?? "") }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let item = rows.first(where: { ids.contains($0.stableID) }) {
                    Button("Изменить") { edit(item) }
                    Button("Удалить…", role: .destructive) { pendingDelete = item }.disabled(repository.isMutating)
                }
            } primaryAction: { ids in if let item = rows.first(where: { ids.contains($0.stableID) }) { edit(item) } }
            .overlay {
                if rows.isEmpty {
                    if repository.isLoadingFuel && !repository.hasFuelSnapshot { ProgressView("Загрузка топлива…") }
                    else { ContentUnavailableView("Нет записей за месяц", systemImage: "fuelpump", description: Text(repository.fuelError ?? "Выберите другой месяц или добавьте запись.")) }
                }
            }
            Divider()
            HStack {
                Button("Изменить") { if let selection { edit(selection) } }.disabled(selection == nil || repository.isMutating)
                Button("Удалить…", role: .destructive) { pendingDelete = selection }.disabled(selection?.id == nil || repository.isMutating)
                Spacer()
                if repository.fuelConnection == .offline { Label("Локальные данные", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                Text("\(rows.count) записей").foregroundStyle(.secondary)
            }.padding(12)
            if let message = workspace.error ?? repository.fuelError ?? repository.cacheWarning {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12)
            }
            if let notice = workspace.notice { Text(notice).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12) }
        }
        .sheet(item: $workspace.imports) { model in MacFuelImportScreen(model: model, repository: repository, coordinator: coordinator) { workspace.imports = nil } }
        .sheet(item: $workspace.editor) { model in
            MacFuelEditor(model: model, repository: repository, coordinator: coordinator, fuelTypes: repository.profile?.profile.fuelTypes ?? []) { saved in
                workspace.editor = nil
                if let saved { workspace.selection = saved.stableID; workspace.notice = "Запись сохранена на сервере." }
            }
        }
        .sheet(isPresented: $workspace.isGsmPresented) {
            MacGsmReportScreen(workspace: workspace, repository: repository, vehicles: vehicles, coordinator: coordinator, selectedDate: workspace.selectedDate)
        }
        .confirmationDialog("Удалить выбранную запись топлива?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) { if let record = pendingDelete { remove(record) }; pendingDelete = nil }
        } message: { Text("Запись будет удалена с сервера.") }
        .confirmationDialog("Перенести пробег маршрутов за \(month) в топливо?", isPresented: $confirmsMileage) {
            Button("Перенести пробег") { syncMileage() }
        } message: { Text("Одна месячная запись пробега будет создана или обновлена на сервере.") }
        .task { do { try await repository.prepare(); try await repository.loadFuel() } catch { } }
        .task { try? await repository.loadGsm() }
        .onChange(of: month) { _, _ in workspace.selection = nil; workspace.error = nil; workspace.notice = nil }
    }
    private var header: some View {
        HStack {
            DatePicker("Месяц", selection: $workspace.selectedDate, displayedComponents: .date).labelsHidden().frame(width: 130)
            if canArchive {
                Picker("Период", selection: $workspace.showsArchive) { Text("Текущие записи").tag(false); Text("Архив до 13 мая 2026").tag(true) }.frame(width: 210)
            }
            TextField("Поиск", text: $workspace.search).frame(maxWidth: 180)
            Spacer()
            if repository.isLoadingFuel || isSynchronizing { ProgressView().controlSize(.small) }
            Button("Добавить") { edit(nil) }.disabled(repository.isMutating)
            Button("Импорт XLSX…") { if let context = coordinator.context { workspace.imports = MacFuelImport(context: context) } }.disabled(repository.isMutating)
            Menu("ГСМ") {
                Button("Отчёт и профиль…") { workspace.isGsmPresented = true }
                Button("Пробег из маршрутов…") { confirmsMileage = true }.disabled(repository.isMutating || isSynchronizing)
            }
            Button { Task { try? await repository.loadFuel(force: true); try? await repository.loadGsm(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить топливо и профиль").disabled(repository.isMutating || repository.isLoadingFuel)
        }
    }
    private func monthSummary(_ value: FuelSummaryMonth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(GsmFuelFormatting.monthLabel(month)).font(.headline)
            HStack { metric("Пробег", value.totalMileage, unit: "км"); metric("Топливо", value.totalLiters, unit: "л"); metric("Норма", value.fuelNorm, unit: "л"); metric("Стоимость", value.fuelCost, unit: "₽") }
            HStack { metric("Компенсация", value.compensation, unit: "₽"); metric("Выплачено", value.paidCompensation, unit: "₽"); metric("Вычет долга", value.effectiveDebtDeductionAmount, unit: "₽"); metric("К выплате", value.projectedPayout, unit: "₽") }
            Text("\(value.compensationStatusLabel) · Остаток топлива: \(value.diffLabel) · Перенос долга: \(number(value.monthCarryoverDebtRub)) ₽").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func metric(_ label: String, _ value: Double, unit: String) -> some View { LabeledContent(label, value: number(value) + " " + unit).frame(maxWidth: .infinity, alignment: .leading) }
    private func number(_ value: Double?) -> String { value.map(GsmFuelFormatting.number) ?? "—" }
    private func title(_ record: FuelRecord) -> String {
        if record.recordType == .fuel { return "Топливо" }
        return record.adjustmentKind == .debtDeduction ? "Вычет долга" : "Выплата компенсации"
    }
    private func edit(_ record: FuelRecord?) {
        guard !repository.isMutating, let context = coordinator.context else { return }
        var value = record ?? FuelRecord(date: MacRouteDate.key(workspace.selectedDate))
        if record == nil, let types = repository.profile?.profile.fuelTypes, types.count == 1 { value.fuelType = types[0] }
        workspace.editor = MacFuelEditorModel(record: value, isNew: record == nil, context: context)
    }
    private func remove(_ record: FuelRecord) {
        guard let context = coordinator.context else { return }
        Task {
            do { try await repository.deleteFuel(record); guard coordinator.accepts(context) else { return }; workspace.selection = nil; workspace.notice = "Запись удалена." }
            catch { if coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { workspace.error = error.localizedDescription } }
        }
    }
    private func syncMileage() {
        guard !isSynchronizing, let context = coordinator.context else { return }
        let requested = month; isSynchronizing = true; workspace.error = nil
        Task {
            defer { isSynchronizing = false }
            do {
                _ = try await routes.loadArchive(force: true)
                guard coordinator.accepts(context), month == requested else { return }
                guard let mileage = RouteMonthlyMileage.build(month: requested, days: routes.archive) else { workspace.notice = "Нет пробега маршрутов за выбранный месяц."; return }
                _ = try await repository.syncMonthlyMileage(mileage)
                guard coordinator.accepts(context), month == requested else { return }; workspace.notice = "Месячный пробег обновлён: \(mileage.totalKm) км."
            } catch { if coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { workspace.error = error.localizedDescription } }
        }
    }
}

private struct FuelTableRow: Identifiable {
    let record: FuelRecord
    var id: String { record.stableID }
}
