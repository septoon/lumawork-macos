import SwiftUI
import EngineerCore

struct MacRequestsScreen: View {
    @Bindable var workspace: MacRequestsWorkspace
    let repository: RequestsRepository
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    let openAccount: () -> Void
    var collectionOverride: RequestCollection? = nil
    var engineerID: String? = nil
    private var collection: RequestCollection { collectionOverride ?? .personal(workspace.scope.source) }
    private var isClosed: Bool { collection.source == .closed }
    private var isGroupArchive: Bool { collection == .groupClosed }
    private var query: String { workspace.search.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
    private var types: [String] { Array(Set(workspace.prepared.map { typeKey($0.record) })).sorted() }
    private func typeKey(_ record: SimpleOneRequestRecord) -> String { record.requestType.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? "" }
    private var rows: [MacRequestRow] {
        let period = Calendar(identifier: .gregorian).dateInterval(of: .month, for: workspace.month)
        return workspace.prepared.filter { row in
            if isGroupArchive, workspace.excludedTypes.contains(typeKey(row.record)) { return false }
            if collectionOverride == nil && workspace.scope == .warehouse && !row.isWarehouse { return false }
            if !isClosed && !workspace.status.contains(row.status) { return false }
            if let engineerID, CoordinationPolicy.engineerKey(row.record) != engineerID { return false }
            if !query.isEmpty { return row.searchText.contains(query) }
            if isGroupArchive {
                let calendar = Calendar.autoupdatingCurrent, today = calendar.startOfDay(for: Date())
                let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
                return row.date.map { $0 >= yesterday && $0 < tomorrow } ?? false
            }
            guard isClosed, !workspace.allDates else { return true }
            return row.date.map { period?.contains($0) ?? false } ?? false
        }
    }
    private var selected: SimpleOneRequestRecord? { rows.first { $0.id == workspace.selection }?.record }
    private var refreshKey: String { "\(coordinator.context?.epoch ?? 0)|\(collection.key)" }
    private var listKey: String { refreshKey + "|\(repository.updatedAt(collection)?.timeIntervalSince1970 ?? 0)" }

    private var content: some View {
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
    }
    var body: some View {
        listLifecycle
        .onChange(of: workspace.scope) { old, new in
            workspace.selection = nil; workspace.detail = nil; workspace.detailError = nil; workspace.isLoadingDetail = false
            if old.source != new.source, collectionOverride == nil { workspace.prepared = [] }
        }
        .onChange(of: collection) { _, _ in workspace.clearResults() }
        .onChange(of: engineerID) { _, _ in workspace.selection = nil; workspace.detail = nil }
        .onChange(of: workspace.search) { _, _ in reconcileSelection() }
        .onChange(of: workspace.month) { _, _ in reconcileSelection() }
        .onChange(of: workspace.allDates) { _, _ in reconcileSelection() }
        .onChange(of: workspace.status) { _, _ in reconcileSelection() }
        .onChange(of: workspace.excludedTypes) { _, _ in reconcileSelection() }
        .task(id: listKey + "|" + (workspace.selection ?? "")) { await fetchDetail(force: false) }
        .sheet(item: $workspace.browserRecord) { record in
            MacSimpleOneBrowser(record: record, coordinator: coordinator, config: config)
        }
    }
    private var listLifecycle: some View {
        content
            .task(id: refreshKey) { try? await repository.load(collection) }
            .task(id: listKey) { await prepareRows() }
    }
    private func exportArchive() {
        let records = repository.records(collection)
        let name = collection == .groupClosed ? "Инженер-group-requests.xlsx" : "Инженер-requests.xlsx"
        workspace.spreadsheet.save(name: name, coordinator: coordinator) {
            try RequestsWorkbookExporter.makeClosedRequestsWorkbook(records: records)
        }
    }
    private func prepareRows() async {
        let captured = coordinator.context, records = repository.records(collection)
        let capturedCollection = collection
        let prepared = await Task.detached(priority: .userInitiated) {
            records.map(MacRequestRow.init).sorted {
                if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                return $0.record.number.localizedStandardCompare($1.record.number) == .orderedDescending
            }
        }.value
        guard !Task.isCancelled, coordinator.context == captured, collection == capturedCollection else { return }
        workspace.prepared = prepared
        reconcileSelection()
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if collectionOverride == nil {
                    Picker("Заявки", selection: $workspace.scope) { ForEach(RequestsScope.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 280)
                } else { Text(collection.title).font(.headline) }
                Spacer(minLength: 0)
                if isClosed {
                    Button { exportArchive() } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Экспортировать весь архив в XLSX")
                        .disabled(workspace.spreadsheet.isBusy || !repository.hasSnapshot(collection))
                    if workspace.spreadsheet.isBusy { ProgressView().controlSize(.small) }
                }
                TextField("Поиск по заявкам", text: $workspace.search).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 240)
                if repository.loading.contains(collection) { ProgressView().controlSize(.small) }
                Button { Task { try? await repository.load(collection, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Полностью обновить заявки").disabled(repository.loading.contains(collection))
            }
            HStack {
                if isGroupArchive {
                    Text(query.isEmpty ? "Сегодня и вчера" : "Поиск по всему архиву").foregroundStyle(.secondary)
                    Menu("Типы заявок") {
                        ForEach(types, id: \.self) { type in
                            Toggle(type.isEmpty ? "Тип не указан" : RequestsPolicy.typeTitle(type), isOn: Binding(
                                get: { !workspace.excludedTypes.contains(type) },
                                set: { visible in if visible { workspace.excludedTypes.remove(type) } else { workspace.excludedTypes.insert(type) } }))
                        }
                    }.disabled(types.isEmpty)
                } else if isClosed {
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
            TableColumn("Статус") { Text(isClosed ? $0.record.state : $0.status) }.width(min: 90, ideal: 130)
            TableColumn(isClosed ? "Выполнена / регистрация" : "Предельный срок") { row in
                Text(isClosed ? RequestsPolicy.effectiveTime(row.record) : row.record.deadline)
                    .foregroundStyle(!isClosed && row.record.isOverdue ? .red : .primary)
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
                if repository.loading.contains(collection) && !repository.hasSnapshot(collection) { ProgressView("Загрузка заявок…") }
                else if let error = repository.errors[collection], !repository.hasSnapshot(collection) {
                    ContentUnavailableView("Не удалось загрузить заявки", systemImage: "exclamationmark.triangle", description: Text(error))
                } else { ContentUnavailableView("Заявки не найдены", systemImage: "checklist", description: Text(query.isEmpty ? "Попробуйте другой период или обновите список." : "Поиск закрытых выполняется по всем датам архива.")) }
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(rows.count) из \(workspace.prepared.count)").foregroundStyle(.secondary)
                if isClosed && !query.isEmpty { Text("Поиск по всему архиву").foregroundStyle(.secondary) }
                Spacer()
                if repository.offline.contains(collection) { Label("Локальные данные", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                if let date = repository.updatedAt(collection) { Text(date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary) }
            }
            if let notice = workspace.spreadsheet.notice { Text(notice).foregroundStyle(.secondary) }
            if let error = workspace.spreadsheet.error ?? repository.errors[collection] ?? repository.cacheWarning {
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
