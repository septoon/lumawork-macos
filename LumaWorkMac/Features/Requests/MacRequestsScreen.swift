import SwiftUI
import EngineerCore

struct MacRequestsScreen: View {
    @Bindable var workspace: MacRequestsWorkspace
    let repository: RequestsRepository
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    let openAccount: () -> Void
    private var query: String { workspace.search.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
    private var rows: [MacRequestRow] {
        let period = Calendar(identifier: .gregorian).dateInterval(of: .month, for: workspace.month)
        return workspace.prepared.filter { row in
            if workspace.scope == .warehouse && !row.isWarehouse { return false }
            if workspace.scope != .closed && !workspace.status.contains(row.status) { return false }
            if !query.isEmpty { return row.searchText.contains(query) }
            guard workspace.scope == .closed, !workspace.allDates else { return true }
            return row.date.map { period?.contains($0) ?? false } ?? false
        }
    }
    private var selected: SimpleOneRequestRecord? { rows.first { $0.id == workspace.selection }?.record }
    private var refreshKey: String { "\(coordinator.context?.epoch ?? 0)|\(workspace.scope.source.rawValue)" }
    private var listKey: String { refreshKey + "|\(repository.updatedAt(workspace.scope.source)?.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        Group {
            if coordinator.simpleOneSession == nil {
                ContentUnavailableView {
                    Label("Войдите в SimpleOne", systemImage: "person.crop.circle.badge.key")
                } description: { Text("Заявки доступны после входа в учётную запись SimpleOne.") }
                actions: { Button("Учётная запись…", action: openAccount) }
            } else {
                VStack(spacing: 0) {
                    controls.padding(12)
                    Divider()
                    HSplitView {
                        table.frame(minWidth: 440)
                        if let record = workspace.detail ?? selected {
                            MacRequestDetailView(record: record, isLoading: workspace.isLoadingDetail, error: workspace.detailError,
                                                 refresh: { loadDetail(force: true) }, openBrowser: { workspace.browserRecord = record })
                                .frame(minWidth: 270, idealWidth: 320, maxWidth: 450)
                        }
                    }
                    Divider()
                    footer.padding(10)
                }
            }
        }
        .task(id: refreshKey) { try? await repository.load(workspace.scope.source) }
        .task(id: listKey) {
            let captured = coordinator.context, records = repository.records(workspace.scope.source)
            let source = workspace.scope.source
            let prepared = await Task.detached(priority: .userInitiated) {
                records.map(MacRequestRow.init).sorted {
                    if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                    return $0.record.number.localizedStandardCompare($1.record.number) == .orderedDescending
                }
            }.value
            guard !Task.isCancelled, coordinator.context == captured, workspace.scope.source == source else { return }
            workspace.prepared = prepared
            reconcileSelection()
        }
        .onChange(of: workspace.scope) { old, new in
            workspace.selection = nil; workspace.detail = nil; workspace.detailError = nil; workspace.isLoadingDetail = false
            if old.source != new.source { workspace.prepared = [] }
        }
        .onChange(of: workspace.search) { _, _ in reconcileSelection() }
        .onChange(of: workspace.month) { _, _ in reconcileSelection() }
        .onChange(of: workspace.allDates) { _, _ in reconcileSelection() }
        .onChange(of: workspace.status) { _, _ in reconcileSelection() }
        .task(id: listKey + "|" + (workspace.selection ?? "")) { await fetchDetail(force: false) }
        .sheet(item: $workspace.browserRecord) { record in
            MacSimpleOneBrowser(record: record, coordinator: coordinator, config: config)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Заявки", selection: $workspace.scope) { ForEach(RequestsScope.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 280)
                Spacer(minLength: 0)
                TextField("Поиск по заявкам", text: $workspace.search).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 240)
                if repository.loading.contains(workspace.scope.source) { ProgressView().controlSize(.small) }
                Button { Task { try? await repository.load(workspace.scope.source, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Полностью обновить заявки").disabled(repository.loading.contains(workspace.scope.source))
            }
            HStack {
                if workspace.scope == .closed {
                    DatePicker("Месяц", selection: $workspace.month, displayedComponents: .date).frame(width: 180).disabled(workspace.allDates || !query.isEmpty)
                    Toggle("Все даты", isOn: $workspace.allDates).toggleStyle(.checkbox).disabled(!query.isEmpty)
                } else {
                    Picker("Статус", selection: $workspace.status) { ForEach(MacRequestStatusFilter.allCases) { Text($0.title).tag($0) } }.frame(width: 200)
                }
                Spacer()
            }
        }
    }
    private var table: some View {
        Table(rows, selection: $workspace.selection) {
            TableColumn("Номер") { Text($0.record.incomingNumber.isEmpty ? $0.record.number : $0.record.incomingNumber) }.width(min: 100, ideal: 125)
            TableColumn("Тип") { Text(RequestsPolicy.typeTitle($0.record.requestType)) }.width(min: 80, ideal: 105)
            TableColumn("Статус") { Text(workspace.scope == .closed ? $0.record.state : $0.status) }.width(min: 90, ideal: 130)
            TableColumn(workspace.scope == .closed ? "Выполнена / регистрация" : "Предельный срок") { row in
                Text(workspace.scope == .closed ? RequestsPolicy.effectiveTime(row.record) : row.record.deadline)
                    .foregroundStyle(workspace.scope != .closed && row.record.isOverdue ? .red : .primary)
            }.width(min: 130, ideal: 155)
            TableColumn("Заказчик") { Text($0.record.customer) }.width(min: 100, ideal: 180)
            TableColumn("Адрес") { Text($0.record.address) }.width(min: 130, ideal: 230)
            TableColumn("Терминал") { Text($0.record.terminalID) }.width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let record = rows.first(where: { ids.contains($0.id) })?.record {
                Button("Открыть в SimpleOne…") { workspace.browserRecord = record }
            }
        } primaryAction: { ids in
            if let record = rows.first(where: { ids.contains($0.id) })?.record { workspace.browserRecord = record }
        }
        .overlay {
            if rows.isEmpty {
                if repository.loading.contains(workspace.scope.source) && !repository.hasSnapshot(workspace.scope.source) { ProgressView("Загрузка заявок…") }
                else if let error = repository.errors[workspace.scope.source], !repository.hasSnapshot(workspace.scope.source) {
                    ContentUnavailableView("Не удалось загрузить заявки", systemImage: "exclamationmark.triangle", description: Text(error))
                } else { ContentUnavailableView("Заявки не найдены", systemImage: "checklist", description: Text(query.isEmpty ? "Попробуйте другой период или обновите список." : "Поиск закрытых выполняется по всем датам архива.")) }
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(rows.count) из \(workspace.prepared.count)").foregroundStyle(.secondary)
                if workspace.scope == .closed && !query.isEmpty { Text("Поиск по всему архиву").foregroundStyle(.secondary) }
                Spacer()
                if repository.offline.contains(workspace.scope.source) { Label("Локальные данные", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                if let date = repository.updatedAt(workspace.scope.source) { Text(date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary) }
            }
            if let error = repository.errors[workspace.scope.source] ?? repository.cacheWarning {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
        }.font(.callout)
    }
    private func reconcileSelection() {
        if let id = workspace.selection, !rows.contains(where: { $0.id == id }) { workspace.selection = nil; workspace.detail = nil }
    }
    private func loadDetail(force: Bool) { Task { await fetchDetail(force: force) } }
    private func fetchDetail(force: Bool) async {
        guard let record = selected, let context = coordinator.context else { workspace.detail = nil; workspace.isLoadingDetail = false; return }
        workspace.detail = repository.cachedDetail(record); workspace.detailError = nil; workspace.isLoadingDetail = true
        defer { if coordinator.accepts(context), workspace.selection == record.id { workspace.isLoadingDetail = false } }
        do {
            let detail = try await repository.detail(record, force: force)
            guard !Task.isCancelled, coordinator.accepts(context), workspace.selection == record.id, selected?.sysUpdatedAt == record.sysUpdatedAt else { return }
            workspace.detail = detail
        } catch {
            guard !AppErrorClassification.isCancellation(error), coordinator.accepts(context), workspace.selection == record.id else { return }
            workspace.detailError = error.localizedDescription
        }
    }
}
