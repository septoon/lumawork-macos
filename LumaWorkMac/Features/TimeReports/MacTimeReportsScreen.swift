import SwiftUI
import Observation
import EngineerCore

struct MacTimeReportRow: Identifiable, Sendable {
    let entry: TimeReportEntry
    let day: String
    let search: String
    var id: String { entry.stableID }
    static func prepare(_ entries: [TimeReportEntry]) -> [Self] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return entries.map { entry in
            Self(entry: entry, day: formatter.string(from: entry.effectiveWorkDate),
                 search: [entry.activity, entry.notes, entry.executor, entry.period, entry.nonWorkCosts].joined(separator: "\n").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
        }
    }
}

struct MacTimeReportBrowserSelection: Identifiable {
    let id = UUID()
    let recordID: String?
    let title: String
}

@MainActor @Observable
final class MacTimeReportsWorkspace {
    var month = Date()
    var allMonths = true
    var day = ""
    var search = ""
    var selection: String?
    var rows: [MacTimeReportRow] = []
    var browser: MacTimeReportBrowserSelection?
    var browserContext: SessionContext?
    func reset() { day = ""; search = ""; selection = nil; rows = []; browser = nil; browserContext = nil }
}

struct MacTimeReportsScreen: View {
    @Bindable var workspace: MacTimeReportsWorkspace
    let repository: RequestsRepository
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    let openAccount: () -> Void
    private var month: String { String(MacRouteDate.key(workspace.month).prefix(7)) }
    private var monthRows: [MacTimeReportRow] { workspace.rows.filter { workspace.allMonths || $0.day.hasPrefix(month) } }
    private var days: [String] { Array(Set(monthRows.map(\.day))).sorted(by: >) }
    private var rows: [MacTimeReportRow] {
        let query = workspace.search.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return monthRows.filter { (workspace.day.isEmpty || $0.day == workspace.day) && (query.isEmpty || $0.search.contains(query)) }
    }
    private var selected: TimeReportEntry? { rows.first { $0.id == workspace.selection }?.entry }
    private var listKey: String { "\(coordinator.context?.epoch ?? 0)|\(repository.timeUpdatedAt?.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        Group {
            if coordinator.simpleOneSession == nil {
                ContentUnavailableView {
                    Label("Войдите в SimpleOne", systemImage: "person.crop.circle.badge.key")
                } description: { Text("Для загрузки трудозатрат нужна учётная запись SimpleOne.") }
                actions: { Button("Учётная запись…", action: openAccount) }
            } else {
                VStack(spacing: 0) {
                    controls.padding(12)
                    Divider()
                    summary.padding(12)
                    Divider()
                    HSplitView {
                        Table(rows, selection: $workspace.selection) {
                            TableColumn("Дата работ", value: \.day).width(100)
                            TableColumn("Активность") { Text($0.entry.activity) }.width(min: 110, ideal: 145)
                            TableColumn("Работа") { Text(TimeReportPolicy.duration($0.entry.workMinutes)) }.width(105)
                            TableColumn("Дорога") { Text(TimeReportPolicy.duration($0.entry.travelMinutes)) }.width(105)
                            TableColumn("Внеурочные") { Text(TimeReportPolicy.duration($0.entry.overtimeMinutes)) }.width(105)
                            TableColumn("Заметки") { Text($0.entry.notes) }.width(min: 150, ideal: 250)
                        }
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let entry = rows.first(where: { ids.contains($0.id) })?.entry { Button("Открыть в SimpleOne…") { open(entry) }.disabled(entry.simpleOneRecordID == nil) }
                        } primaryAction: { ids in if let entry = rows.first(where: { ids.contains($0.id) })?.entry { open(entry) } }
                        .overlay {
                            if rows.isEmpty {
                                if repository.isLoadingTime && repository.timeUpdatedAt == nil { ProgressView("Загрузка трудозатрат…") }
                                else if let error = repository.timeError, repository.timeUpdatedAt == nil { ContentUnavailableView("Не удалось загрузить трудозатраты", systemImage: "exclamationmark.triangle", description: Text(error)) }
                                else { ContentUnavailableView("Трудозатраты не найдены", systemImage: "clock", description: Text("Измените период, поиск или обновите данные.")) }
                            }
                        }
                        if let selected { detail(selected).frame(minWidth: 250, idealWidth: 290, maxWidth: 400) }
                    }
                    Divider()
                    footer.padding(10)
                }
            }
        }
        .task(id: coordinator.context) { try? await repository.loadTimeReports() }
        .task(id: listKey) {
            let captured = coordinator.context, entries = repository.timeEntries
            let rows = await Task.detached(priority: .userInitiated) { MacTimeReportRow.prepare(entries) }.value
            guard !Task.isCancelled, coordinator.context == captured else { return }
            workspace.rows = rows; reconcileSelection()
        }
        .onChange(of: month) { _, _ in workspace.day = ""; reconcileSelection() }
        .onChange(of: workspace.allMonths) { _, _ in workspace.day = ""; reconcileSelection() }
        .onChange(of: workspace.day) { _, _ in reconcileSelection() }
        .onChange(of: workspace.search) { _, _ in reconcileSelection() }
        .sheet(item: $workspace.browser, onDismiss: refreshAfterBrowser) { item in
            MacSimpleOneBrowser(timeReportRecordID: item.recordID, title: item.title, coordinator: coordinator, config: config)
        }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                DatePicker("Месяц", selection: $workspace.month, displayedComponents: .date).frame(width: 185).disabled(workspace.allMonths)
                Toggle("Все месяцы", isOn: $workspace.allMonths).toggleStyle(.checkbox)
                Spacer()
                TextField("Поиск", text: $workspace.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                if repository.isLoadingTime { ProgressView().controlSize(.small) }
                Button { Task { try? await repository.loadTimeReports(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить из SimpleOne").disabled(repository.isLoadingTime)
            }
            HStack {
                Picker("День", selection: $workspace.day) {
                    Text("Все дни").tag("")
                    ForEach(days, id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                Spacer()
                Button("Создать в SimpleOne…") {
                    workspace.browserContext = coordinator.context
                    workspace.browser = MacTimeReportBrowserSelection(recordID: nil, title: "Создать трудозатраты")
                }
            }
        }
    }
    private var summary: some View {
        let work = rows.reduce(0) { $0 + $1.entry.workMinutes }, travel = rows.reduce(0) { $0 + $1.entry.travelMinutes }
        let overtime = rows.reduce(0) { $0 + $1.entry.overtimeMinutes }, dayCount = Set(rows.map(\.day)).count
        return HStack(spacing: 24) {
            metric("Работа", TimeReportPolicy.duration(work))
            metric("Дорога", TimeReportPolicy.duration(travel))
            metric("Всего", TimeReportPolicy.duration(work + travel))
            metric("Внеурочные", TimeReportPolicy.duration(overtime))
            metric("Дни / записи", "\(dayCount) / \(rows.count)")
            Spacer(minLength: 0)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).monospacedDigit() }
    }
    private func detail(_ entry: TimeReportEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.activity).font(.headline)
                Button("Открыть в SimpleOne…") { open(entry) }.disabled(entry.simpleOneRecordID == nil)
                metric("Дата работ", entry.workDateRaw ?? entry.createdAtRaw)
                metric("Когда создано", entry.createdAtRaw)
                metric("Период", entry.period)
                metric("Исполнитель", entry.executor)
                metric("Работа", TimeReportPolicy.duration(entry.workMinutes))
                metric("Дорога", TimeReportPolicy.duration(entry.travelMinutes))
                metric("Внеурочные работы", entry.isOvertime ? "Да" : "Нет")
                metric("Внеурочные", TimeReportPolicy.duration(entry.overtimeMinutes))
                if !entry.nonWorkCosts.isEmpty { metric("Трудозатраты нерабочие", entry.nonWorkCosts) }
                if !entry.notes.isEmpty { metric("Рабочие заметки", entry.notes) }
            }.textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(rows.count) из \(workspace.rows.count)").foregroundStyle(.secondary)
                Spacer()
                if repository.timeOffline { Label("Локальные данные", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                if let date = repository.timeUpdatedAt { Text(date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary) }
            }
            if let error = repository.timeError ?? repository.cacheWarning { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
        }.font(.callout)
    }
    private func open(_ entry: TimeReportEntry) {
        guard let id = entry.simpleOneRecordID, !id.isEmpty else { return }
        workspace.browserContext = coordinator.context
        workspace.browser = MacTimeReportBrowserSelection(recordID: id, title: entry.activity)
    }
    private func refreshAfterBrowser() {
        guard let context = workspace.browserContext else { return }
        workspace.browserContext = nil
        Task { guard coordinator.accepts(context) else { return }; try? await repository.loadTimeReports(force: true) }
    }
    private func reconcileSelection() {
        if !workspace.day.isEmpty && !days.contains(workspace.day) { workspace.day = "" }
        if let id = workspace.selection, !rows.contains(where: { $0.id == id }) { workspace.selection = nil }
    }
}
