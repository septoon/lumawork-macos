import SwiftUI
import EngineerCore

@MainActor @Observable
final class MacWorkScheduleWorkspace {
    var city = ""
    var date = Date()
    var initialized = false
    var selection: String?
    var search = ""
    func reset() { city = ""; date = Date(); initialized = false; selection = nil; search = "" }
    var year: Int { Calendar(identifier: .gregorian).component(.year, from: date) }
    var month: Int { Calendar(identifier: .gregorian).component(.month, from: date) }
}
struct MacWorkScheduleView: View {
    @Bindable var model: MacWorkScheduleWorkspace
    let container: MacSessionContainer
    @Environment(\.dismiss) private var dismiss
    private var journals: [WorkScheduleJournal] { container.scheduleJournals.value("all") ?? [] }
    private var journal: WorkScheduleJournal? { WorkScheduleSelection.journal(in: journals, matching: .init(cityName: model.city, year: model.year, month: model.month)) }
    private var schedule: WorkSchedule? { journal.flatMap { container.schedules.value($0.id) } }
    private var employees: [WorkScheduleEmployee] { (schedule?.employees ?? []).filter { model.search.isEmpty || ($0.name + " " + $0.login).localizedStandardContains(model.search) } }
    private var loading: Bool { container.scheduleJournals.isLoading("all") || journal.map { container.schedules.isLoading($0.id) } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("График работы").font(.title2.weight(.semibold))
                Spacer(); if loading { ProgressView().controlSize(.small) }
                Button("Обновить") { Task { await load(force: true) } }.disabled(loading)
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Город", selection: $model.city) { ForEach(WorkScheduleSelection.cityNames(in: journals), id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 300)
                DatePicker("Дата", selection: $model.date, displayedComponents: .date).environment(\.locale, Locale(identifier: "ru_RU"))
                TextField("Найти сотрудника", text: $model.search).frame(maxWidth: 260)
            }
            if let error = journal.flatMap({ container.schedules.errors[$0.id] }) ?? container.scheduleJournals.errors["all"] { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let warning = container.schedules.cacheWarning ?? container.scheduleJournals.cacheWarning { Text(warning).font(.callout).foregroundStyle(.secondary) }
            if container.coordinator.simpleOneSession == nil { ContentUnavailableView("Требуется вход в SimpleOne", systemImage: "person.crop.circle") }
            else if let schedule { grid(schedule) }
            else if !loading, journal.flatMap({ container.schedules.errors[$0.id] }) != nil || container.scheduleJournals.errors["all"] != nil { ContentUnavailableView("Не удалось загрузить график", systemImage: "exclamationmark.triangle") }
            else if !loading { ContentUnavailableView("Нет графика за этот месяц", systemImage: "calendar", description: Text(model.city.isEmpty ? "Журналы не найдены." : model.city)) }
            else { Spacer() }
            if let audit = schedule?.auditInfo {
                HStack { if let name = audit.updatedBy { Text("Обновил: " + name) }; if let date = audit.updatedAt { Text(date, format: .dateTime.day().month().year().hour().minute()) } }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(minWidth: 820, idealWidth: 1100, minHeight: 500, idealHeight: 680)
        .task(id: container.coordinator.context) { await load() }
        .task(id: journal?.id) { await loadSchedule() }
        .onChange(of: model.city) { _, _ in model.selection = nil }
    }
    private func grid(_ schedule: WorkSchedule) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(employees) { employee in
                        Button { model.selection = employee.id } label: {
                            HStack(spacing: 0) {
                                Text(employee.name).frame(width: 220, alignment: .leading).lineLimit(2)
                                ForEach(1...max(1, min(31, schedule.daysInMonth)), id: \.self) { day in
                                    let value = employee.value(for: day)
                                    Text(value.map { $0.hours == 0 ? "—" : $0.hours.formatted(.number.precision(.fractionLength(0...2))) } ?? "—")
                                        .frame(width: 38, height: 34).foregroundStyle(value?.isActive == true ? .primary : .secondary)
                                        .background(day == Calendar.current.component(.day, from: model.date) ? Color.accentColor.opacity(0.08) : Color.clear)
                                }
                                Text(employee.totalHours, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
                            }.contentShape(Rectangle()).padding(.horizontal, 8)
                                .background(model.selection == employee.id ? Color.accentColor.opacity(0.16) : Color.clear)
                        }.buttonStyle(.plain).accessibilityLabel(employee.name)
                        Divider()
                    }
                    HStack(spacing: 0) {
                        Text("Всего работают").frame(width: 220, alignment: .leading)
                        ForEach(1...max(1, min(31, schedule.daysInMonth)), id: \.self) { day in Text(String(schedule.dailyTotals.first { $0.day == day }?.count ?? 0)).frame(width: 38, height: 34) }
                        Spacer().frame(width: 70)
                    }.padding(.horizontal, 8).fontWeight(.semibold)
                } header: {
                    HStack(spacing: 0) {
                        Text("Сотрудник").frame(width: 220, alignment: .leading)
                        ForEach(1...max(1, min(31, schedule.daysInMonth)), id: \.self) { day in
                            Button(String(day)) { if let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: model.year, month: model.month, day: day)) { model.date = date } }.buttonStyle(.plain).frame(width: 38, height: 34).help("Выбрать день \(day)")
                        }
                        Text("Часы").frame(width: 70)
                    }.padding(.horizontal, 8).fontWeight(.semibold).background(.background)
                }
            }
        }
    }
    private func load(force: Bool = false) async {
        let captured = container.coordinator.context
        try? await container.scheduleJournals.load("all", force: force) { [config = container.config] session in try await SimpleOneRequestsService(config: config).fetchWorkScheduleJournals(authKey: session.authKey) }
        guard captured == container.coordinator.context else { return }
        if !model.initialized, !journals.isEmpty {
            let initial = WorkScheduleSelection.initial(journals: journals, profileCity: container.coordinator.session?.user.profile?.city, currentYear: model.year, currentMonth: model.month)
            model.city = initial.cityName; model.initialized = true
        }
        await loadSchedule(force: force)
    }
    private func loadSchedule(force: Bool = false) async {
        guard let journal else { return }
        try? await container.schedules.load(journal.id, force: force) { [config = container.config] session in try await SimpleOneRequestsService(config: config).fetchWorkSchedule(journal: journal, authKey: session.authKey) }
    }
}
