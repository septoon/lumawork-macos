import SwiftUI
import Charts
import Observation
import EngineerCore

@MainActor @Observable
final class MacAnalyticsWorkspace {
    var data = ClosedRequestsAnalyticsData(records: [])
    var selectedMonth: String?
    var isPreparing = false
    func reset() { data = ClosedRequestsAnalyticsData(records: []); selectedMonth = nil; isPreparing = false }
}

struct MacAnalyticsScreen: View {
    @Bindable var workspace: MacAnalyticsWorkspace
    let repository: RequestsRepository
    let coordinator: EngineerApplicationCoordinator
    let openAccount: () -> Void
    private let collection = RequestCollection.personal(.closed)
    private var data: ClosedRequestsAnalyticsData { workspace.data }
    private var listKey: String { "\(coordinator.context?.epoch ?? 0)|\(repository.updatedAt(collection)?.timeIntervalSince1970 ?? 0)" }
    private var selectedMonth: String? { workspace.selectedMonth ?? data.latestMonthID }

    var body: some View {
        Group {
            if coordinator.simpleOneSession == nil {
                ContentUnavailableView {
                    Label("Войдите в SimpleOne", systemImage: "person.crop.circle.badge.key")
                } description: { Text("Аналитика строится по личному архиву закрытых заявок.") }
                actions: { Button("Учётная запись…", action: openAccount) }
            } else {
                VStack(spacing: 0) {
                    controls.padding(12)
                    Divider()
                    if !repository.hasSnapshot(collection) {
                        if repository.loading.contains(collection) { ProgressView("Загрузка архива…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else if let error = repository.errors[collection] { ContentUnavailableView("Не удалось загрузить архив", systemImage: "exclamationmark.triangle", description: Text(error)) }
                        else { ContentUnavailableView("Нет данных для аналитики", systemImage: "chart.bar", description: Text("Обновите личный архив заявок.")) }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                summary
                                monthlyChart
                                monthlyDetail
                                types
                                distributions
                            }.padding(16).frame(maxWidth: 1200)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Divider()
                    footer.padding(10)
                }
            }
        }
        .task(id: coordinator.context) { try? await repository.load(collection) }
        .task(id: listKey) { await prepare() }
    }
    private var controls: some View {
        HStack {
            Text("Личный архив").font(.headline)
            Text("Все даты").foregroundStyle(.secondary)
            Spacer()
            if repository.loading.contains(collection) || workspace.isPreparing { ProgressView().controlSize(.small) }
            Button { Task { try? await repository.load(collection, force: true) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(repository.loading.contains(collection))
        }
    }
    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 12) {
            metric("Выполнено", "\(data.completedCount)", "без возврата ТО")
            metric("Месяцев", "\(data.monthlyStats.count)", "в истории")
            metric("Последний месяц", data.latestMonth.map { "\($0.count)" } ?? "—", data.latestMonth?.title ?? "Нет данных")
            metric("Топ тип", data.topRequestType.map { "\($0.count)" } ?? "—", data.topRequestType?.title ?? "Нет данных")
            metric("Возврат ТО", "\(data.returnEquipCount)", "отдельный учёт")
            metric("SLA соблюдён / нарушен", "\(data.slaMetCount) / \(data.slaBreachedCount)", "при наличии срока и даты выполнения")
        }
    }
    private func metric(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var monthlyChart: some View {
        GroupBox("График по месяцам") {
            if data.monthlyChartStats.isEmpty { empty("Нет выполненных заявок для графика.") }
            else {
                Chart(data.monthlyChartStats) { item in
                    BarMark(x: .value("Месяц", item.id), y: .value("Заявки", item.count))
                        .foregroundStyle(item.id == selectedMonth ? Color.accentColor : Color.secondary.opacity(0.45))
                        .accessibilityLabel(item.title).accessibilityValue("\(item.count) заявок")
                }
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: min(12, data.monthlyChartStats.count))
                .chartScrollPosition(initialX: data.monthlyChartStats.last?.id ?? "")
                .chartXSelection(value: $workspace.selectedMonth)
                .frame(height: 210).padding(8)
            }
        }
    }
    private var monthlyDetail: some View {
        GroupBox("Распределение по месяцам") {
            HStack(alignment: .top, spacing: 24) {
                Table(data.monthlyStats, selection: $workspace.selectedMonth) {
                    TableColumn("Месяц", value: \.title)
                    TableColumn("Выполнено") { Text("\($0.count)").monospacedDigit() }.width(90)
                }.frame(minWidth: 230, maxWidth: 400).frame(height: 280)
                VStack(alignment: .leading, spacing: 10) {
                    if let id = selectedMonth, let item = data.monthlyItem(id: id) {
                        Text(item.title.capitalized).font(.headline)
                        calendar(monthID: id)
                    } else { empty("Выберите месяц для календаря.") }
                    if let month = data.topMonth { Text("Топ месяц: \(month.title) · \(month.count)").foregroundStyle(.secondary) }
                    if let day = data.topDay { Text("Топ день: \(day.title) · \(day.count)").foregroundStyle(.secondary) }
                }.frame(minWidth: 280, maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.padding(8)
        }
    }
    private func calendar(monthID: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
            ForEach(Array(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"].enumerated()), id: \.offset) { _, title in
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(data.monthCalendarDays(for: monthID)) { day in
                if day.isPlaceholder { Color.clear.frame(height: 34).accessibilityHidden(true) }
                else {
                    HStack(spacing: 4) {
                        Text("\(day.dayNumber ?? 0)").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(day.count == 0 ? "—" : "\(day.count)").monospacedDigit()
                    }.font(.caption).padding(6).frame(height: 34)
                        .background(day.count > 0 ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.dayNumber ?? 0): \(day.count) заявок")
                }
            }
        }.frame(maxWidth: 500)
    }
    private var types: some View {
        GroupBox("Распределение по типам заявок") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Только выполненные заявки без возврата ТО").font(.caption).foregroundStyle(.secondary)
                if data.requestTypeStats.isEmpty { empty("Нет данных для распределения по типам.") }
                else {
                    Chart(data.requestTypeStats) { item in
                        BarMark(x: .value("Заявки", item.count), y: .value("Тип", item.title))
                            .annotation(position: .trailing) { Text("\(item.count)").font(.caption).monospacedDigit() }
                    }.frame(height: CGFloat(max(1, data.requestTypeStats.count) * 35)).padding(8)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var distributions: some View {
        HStack(alignment: .top, spacing: 16) {
            distribution("Статусы", items: data.statusStats)
            distribution("Исполнители", items: data.assigneeStats)
        }
    }
    private func distribution(_ title: String, items: [ClosedRequestsAnalyticsData.DistributionItem]) -> some View {
        GroupBox(title) {
            Table(items) {
                TableColumn("Значение", value: \.title)
                TableColumn("Заявок") { Text("\($0.count)").monospacedDigit() }.width(75)
            }.frame(height: 200)
        }.frame(maxWidth: .infinity)
    }
    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Выполнено — код закрытия «Решено с выездом».").foregroundStyle(.secondary)
                Spacer()
                if repository.offline.contains(collection) { Label("Локальные данные", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                if let date = repository.updatedAt(collection) { Text(date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary) }
            }
            if let error = repository.errors[collection] ?? repository.cacheWarning { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
        }.font(.callout)
    }
    private func prepare() async {
        let captured = coordinator.context, records = repository.records(collection)
        workspace.isPreparing = true
        defer { if !Task.isCancelled, coordinator.context == captured { workspace.isPreparing = false } }
        let result = await Task.detached(priority: .userInitiated) { ClosedRequestsAnalyticsData(records: records) }.value
        guard !Task.isCancelled, coordinator.context == captured else { return }
        workspace.data = result
        if let id = workspace.selectedMonth, result.monthlyItem(id: id) == nil { workspace.selectedMonth = nil }
    }
}
