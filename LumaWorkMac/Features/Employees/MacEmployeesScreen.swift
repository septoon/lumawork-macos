import SwiftUI
import AppKit
import EngineerCore

@MainActor @Observable
final class MacEmployeesWorkspace {
    var city: SimpleOneEmployeeAddress?
    var search = ""
    var citySearch = ""
    var selection: String?
    var showsCityPicker = false
    var showsSchedule = false
    var error: String?
    let schedule = MacWorkScheduleWorkspace()
    var key: String { (city?.id ?? "") + "|" + search.trimmingCharacters(in: .whitespacesAndNewlines) }
    func reset() { city = nil; search = ""; citySearch = ""; selection = nil; showsCityPicker = false; showsSchedule = false; error = nil; schedule.reset() }
}
struct MacEmployeesScreen: View {
    @Bindable var model: MacEmployeesWorkspace
    let container: MacSessionContainer
    let openAccount: () -> Void
    private var directory: EmployeeDirectory? { container.employeeDirectories.value(model.key) }
    private var selected: SimpleOneEmployee? {
        guard let id = model.selection else { return nil }
        return container.employeeDetails.value(id) ?? directory?.employees.first { $0.id == id }
    }
    var body: some View {
        HSplitView {
            content.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if model.selection != nil {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button { model.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть сведения") }.padding(10)
                    employeeInspector.padding(16)
                }.frame(minWidth: 280, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)
            }
        }
        .searchable(text: $model.search, prompt: "ФИО, логин, должность")
        .task(id: container.coordinator.context) { await bootstrap() }
        .task(id: model.key) { do { try await Task.sleep(for: .milliseconds(300)); await load() } catch {} }
        .sheet(isPresented: $model.showsSchedule) { MacWorkScheduleView(model: model.schedule, container: container) }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Город", selection: Binding(get: { model.city?.id ?? "" }, set: { id in model.city = savedCities.first { $0.id == id }; model.selection = nil })) {
                    Text("Выберите город").tag("")
                    ForEach(savedCities) { Text($0.title).tag($0.id) }
                }.frame(maxWidth: 280)
                Button { model.showsCityPicker = true } label: { Label("Добавить город", systemImage: "plus") }
                    .popover(isPresented: $model.showsCityPicker) { cityPicker }
                if let city = model.city { Button { remove(city) } label: { Image(systemName: "minus") }.help("Убрать город из сохранённых") }
                Spacer()
                Button("График работы…") { model.showsSchedule = true }
                if container.employeeDirectories.isLoading(model.key) { ProgressView().controlSize(.small) }
                Button { Task { await load(force: true) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(model.city == nil || container.employeeDirectories.isLoading(model.key))
            }.padding(12)
            if container.coordinator.simpleOneSession == nil {
                ContentUnavailableView { Label("Требуется вход в SimpleOne", systemImage: "person.crop.circle.badge.exclamationmark") } actions: { Button("Учётная запись", action: openAccount) }
            } else if model.city == nil {
                ContentUnavailableView("Выберите город", systemImage: "building.2", description: Text("Добавьте город для просмотра сотрудников."))
            } else {
                if let error = model.error ?? container.employeeDirectories.errors[model.key] { Text(error).foregroundStyle(.red).padding(8).textSelection(.enabled) }
                if container.employeeDirectories.offline.contains(model.key) { Label("Нет связи. Показаны сохранённые данные.", systemImage: "wifi.slash").font(.callout).foregroundStyle(.secondary) }
                if let warning = container.employeeDirectories.cacheWarning { Text(warning).font(.callout).foregroundStyle(.secondary) }
                Table(directory?.employees ?? [], selection: $model.selection) {
                    TableColumn("Сотрудник", value: \.fullName)
                    TableColumn("Должность", value: \.position)
                    TableColumn("Телефон", value: \.phone)
                    TableColumn("Рабочая почта", value: \.email)
                }.overlay {
                    if directory == nil, container.employeeDirectories.isLoading(model.key) { ProgressView("Загрузка сотрудников…") }
                    else if directory == nil, container.employeeDirectories.errors[model.key] != nil { ContentUnavailableView("Не удалось загрузить сотрудников", systemImage: "exclamationmark.triangle") }
                    else if directory?.employees.isEmpty == true { ContentUnavailableView("Сотрудники не найдены", systemImage: "person.2") }
                }
                HStack { Text("Сотрудников: \(directory?.totalCount ?? 0)"); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }
    private var savedCities: [SimpleOneEmployeeAddress] { container.employeeCities.value("saved") ?? [] }
    private var cityPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить город").font(.headline)
            TextField("Не менее двух символов", text: $model.citySearch)
            if container.employeeCities.isLoading("search|" + model.citySearch) { ProgressView().controlSize(.small) }
            if let error = container.employeeCities.errors["search|" + model.citySearch] { Text(error).foregroundStyle(.red) }
            List(container.employeeCities.value("search|" + model.citySearch) ?? []) { city in
                Button { Task { await save(city) } } label: { VStack(alignment: .leading) { Text(city.title); if !city.subtitle.isEmpty { Text(city.subtitle).font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain)
            }.frame(height: 220)
        }.padding(16).frame(width: 360)
            .task(id: model.citySearch) {
                let query = model.citySearch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard query.count >= 2 else { return }
                do { try await Task.sleep(for: .milliseconds(300)); try await container.employeeCities.load("search|" + model.citySearch) { [config = container.config] session in try await SimpleOneRequestsService(config: config).fetchEmployeeAddressOptions(query: query, authKey: session.authKey) } } catch {}
            }
    }
    @ViewBuilder private var employeeInspector: some View {
        if let employee = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(employee.fullName).font(.title3.weight(.semibold))
                    Text(employee.roleText).foregroundStyle(.secondary)
                    HStack { contact("Позвонить", value: employee.phone, scheme: "tel"); contact("Написать", value: employee.email, scheme: "mailto") }
                    if let error = container.employeeDetails.errors[employee.id] { Text(error).foregroundStyle(.red) }
                    if container.employeeDetails.isLoading(employee.id) { ProgressView().controlSize(.small) }
                    if employee.detailSections.isEmpty {
                        LabeledContent("Логин", value: employee.login); LabeledContent("Телефон", value: employee.phone); LabeledContent("Почта", value: employee.email)
                    }
                    ForEach(employee.detailSections) { section in
                        Divider(); Text(section.title).font(.headline)
                        ForEach(section.fields) { field in VStack(alignment: .leading) { Text(field.title).font(.caption).foregroundStyle(.secondary); Text(field.value) } }
                    }
                }.textSelection(.enabled)
            }.task(id: employee.id) {
                try? await container.employeeDetails.load(employee.id) { [config = container.config] session in try await SimpleOneRequestsService(config: config).fetchEmployeeDetail(sysID: employee.id, fallback: employee, authKey: session.authKey) }
            }
        }
    }
    private func contact(_ title: String, value: String, scheme: String) -> some View {
        Button(title) { var components = URLComponents(); components.scheme = scheme; components.path = value.trimmingCharacters(in: .whitespacesAndNewlines); if let url = components.url { NSWorkspace.shared.open(url) } }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func bootstrap() async {
        guard let captured = container.coordinator.context, let session = container.coordinator.simpleOneSession else { return }
        do {
            try await container.employeeCities.loadLocal("saved")
            if container.employeeCities.value("saved") == nil {
                try await container.employeeDetails.load(session.user.sysID) { [config = container.config] session in try await SimpleOneRequestsService(config: config).fetchEmployeeDetail(sysID: session.user.sysID, authKey: session.authKey) }
                guard container.coordinator.accepts(captured) else { return }
                if let city = container.employeeDetails.value(session.user.sysID)?.address { try await container.employeeCities.setLocal([city], key: "saved", expectedContext: captured) }
            }
            guard container.coordinator.accepts(captured) else { return }
            if model.city == nil { model.city = savedCities.first }
            await load()
        } catch { show(error, captured) }
    }
    private func load(force: Bool = false) async {
        guard let city = model.city else { return }; let query = model.search, key = model.key
        try? await container.employeeDirectories.load(key, force: force) { [config = container.config] session in
            let result = try await SimpleOneRequestsService(config: config).fetchEmployees(address: city, searchText: query, authKey: session.authKey)
            return EmployeeDirectory(employees: result.employees, totalCount: result.totalCount)
        }
    }
    private func save(_ city: SimpleOneEmployeeAddress) async {
        guard let captured = container.coordinator.context else { return }
        do { try await container.employeeCities.loadLocal("saved"); var cities = savedCities; if !cities.contains(where: { $0.id == city.id }) { cities.append(city) }; try await container.employeeCities.setLocal(cities, key: "saved", expectedContext: captured); guard container.coordinator.accepts(captured) else { return }; model.city = city; model.selection = nil; model.showsCityPicker = false }
        catch { show(error, captured) }
    }
    private func remove(_ city: SimpleOneEmployeeAddress) {
        guard let captured = container.coordinator.context else { return }
        Task { do { try await container.employeeCities.setLocal(savedCities.filter { $0.id != city.id }, key: "saved", expectedContext: captured); guard container.coordinator.accepts(captured) else { return }; model.city = savedCities.first; model.selection = nil } catch { show(error, captured) } }
    }
    private func show(_ error: Error, _ context: SessionContext) { if container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { model.error = error.localizedDescription } }
}
