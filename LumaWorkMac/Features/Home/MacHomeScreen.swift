import SwiftUI
import EngineerCore

struct MacHomeScreen: View {
    let model: MacRouteWorkspace
    let repository: RouteDayRepository
    let coordinator: EngineerApplicationCoordinator
    let mapsRouteURL: String?
    @Environment(\.openURL) private var openURL
    let changeDate: (Date) -> Void
    let changeWorkType: (RouteWorkType) -> Void
    let openArchivedDay: (RouteDayRecord) -> Void
    @Bindable private var presentation: MacRouteWorkspace
    init(model: MacRouteWorkspace, repository: RouteDayRepository, coordinator: EngineerApplicationCoordinator, mapsRouteURL: String?, changeDate: @escaping (Date) -> Void, changeWorkType: @escaping (RouteWorkType) -> Void, openArchivedDay: @escaping (RouteDayRecord) -> Void) {
        self.model = model; self.repository = repository; self.coordinator = coordinator
        self.mapsRouteURL = mapsRouteURL
        self.changeDate = changeDate; self.changeWorkType = changeWorkType; self.openArchivedDay = openArchivedDay; presentation = model
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let draft = model.draft {
                routeContent(draft)
                Divider()
                footer(draft)
            } else if !model.isLoading {
                ContentUnavailableView("Маршрут не загружен", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Повторите загрузку после восстановления связи."))
            } else { Spacer() }
            feedback
        }
        .task(id: model.key) { await model.load(repository: repository, coordinator: coordinator) }
        .onChange(of: coordinator.context) { _, _ in Task { await model.load(repository: repository, coordinator: coordinator, force: true) } }
        .sheet(isPresented: $presentation.isArchivePresented) {
            MacRouteArchiveScreen(repository: repository, selectedDate: model.selectedDate) { record in
                model.isArchivePresented = false
                openArchivedDay(record)
            }
        }
        .sheet(isPresented: $presentation.isMapPresented) {
            if let draft = model.draft { MacRouteMapView(model: model, draft: draft, repository: repository, coordinator: coordinator) }
        }
        .sheet(isPresented: $presentation.isRemotePresented) {
            if let draft = model.draft, let remote = draft.remote {
                MacRemoteRouteView(record: remote) { Task { await model.useRemote(repository: repository) } }
            }
        }
        .alert("Отправить маршрут?", isPresented: $presentation.isSendConfirmationPresented) {
            Button("Отправить") { Task { await model.send(repository: repository) } }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("\(model.key.date), \(model.workType.title). Маршрут будет сохранён на сервере и доступен на других устройствах.")
        }
        .alert("Загрузить сохранённый маршрут?", isPresented: $presentation.isLocalReloadConfirmationPresented) {
            Button("Загрузить", role: .destructive) { Task { await model.reloadLocal(repository: repository, coordinator: coordinator) } }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Несохранённые изменения этого окна будут заменены последними локальными данными. Черновик другого окна останется сохранён.")
        }
    }
    private var header: some View {
            HStack(spacing: 12) {
                DatePicker("Дата", selection: Binding(get: { model.selectedDate }, set: changeDate), displayedComponents: .date).frame(width: 190)
                Picker("Работа", selection: Binding(get: { model.workType }, set: changeWorkType)) {
                    ForEach(RouteWorkType.allCases) { Text($0.title).tag($0) }
                }.frame(width: 130)
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Загрузка маршрута") }
                Spacer()
                Button("Карта и пробег") { model.isMapPresented = true }.disabled(model.draft == nil || model.isBusy)
                Button("Яндекс Карты") {
                    guard let url = mapURL else { return }
                    openURL(url) { accepted in
                        if !accepted { model.error = "Не удалось открыть Яндекс Карты." }
                    }
                }.disabled(mapURL == nil || model.isBusy)
                    .help(mapURL == nil ? "Для маршрута нужны минимум два адреса и настроенный адрес карт." : "Открыть текущий маршрут в Яндекс Картах")
                Button("Архив") { model.isArchivePresented = true }
                Button { Task { await model.load(repository: repository, coordinator: coordinator, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить маршрут").disabled(model.isLoading || model.isBusy)
            }.padding(12)
    }
    private var mapURL: URL? {
        guard let record = model.draft?.record else { return nil }
        let plan = repository.mapPlan(for: record)
        return RouteMapLinks.webURL(baseURL: mapsRouteURL, addresses: plan.addresses, coordinateOverrides: plan.coordinateOverrides)
    }
    private func footer(_ draft: RouteDraftController) -> some View {
        VStack(spacing: 0) {
                HStack {
                    Label(draft.isDirty ? "Есть несохранённые изменения" : (repository.snapshot(for: draft.record.key)?.draft?.queued == true ? "Сохранён в очереди" : draft.savedRevision != nil ? "Локальный черновик" : draft.record.sent ? "Отправлен" : "Маршрут дня"), systemImage: draft.isDirty ? "pencil" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Сохранить черновик") { Task { await model.saveShowingError(repository: repository) } }.disabled(!draft.isDirty || model.isBusy)
                    Button("Отправить") { model.isSendConfirmationPresented = true }.disabled(draft.validationMessage != nil || model.isBusy || repository.isSending(draft.record.key))
                        .help(draft.validationMessage ?? "Отправить маршрут на сервер")
                }.padding(12)
                if let validation = draft.validationMessage { Text(validation).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8) }
        }
    }
    @ViewBuilder private var feedback: some View {
            if let message = model.error ?? model.notice {
                HStack {
                    Label(message, systemImage: model.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil; model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть сообщение")
                }.font(.callout).padding(12)
            }
    }
    private func routeContent(_ draft: RouteDraftController) -> some View {
        VStack(spacing: 0) {
            if draft.savedRevision != repository.snapshot(for: draft.record.key)?.draft?.revision {
                HStack {
                    Label("В другом окне изменён локальный черновик.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Загрузить сохранённый") { model.isLocalReloadConfirmationPresented = true }
                }.padding(12)
            }
            if repository.snapshot(for: draft.record.key)?.connection == .offline {
                Label("Нет связи. Показаны локальные данные.", systemImage: "wifi.slash").foregroundStyle(.secondary).padding(8)
            }
            if draft.hasRemoteConflict {
                HStack {
                    Label("Серверный маршрут изменился. Черновик сохранён.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Сравнить") { model.isRemotePresented = true }.disabled(draft.remote == nil)
                }.padding(12)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Пробег, км").font(.caption).foregroundStyle(.secondary)
                    TextField("Пробег, км", value: Binding(get: { draft.record.distanceKm }, set: { draft.setDistance($0) }), format: .number)
                }.frame(width: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Одометр на начало месяца, км").font(.caption).foregroundStyle(.secondary)
                    TextField("Одометр на начало месяца", value: Binding(get: { draft.record.periodStartOdometer }, set: { draft.setOdometer($0) }), format: .number)
                }.frame(width: 210)
                Spacer()
                Button { draft.addStop(); model.selectedStopID = draft.record.stops[draft.record.stops.count - 2].id } label: { Label("Точка", systemImage: "plus") }
                Button { move(draft, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Переместить точку вверх")
                Button { move(draft, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Переместить точку вниз")
                Button { if let id = model.selectedStopID { draft.removeStop(id) } } label: { Image(systemName: "minus") }.help("Удалить точку")
                    .disabled(!canRemove(draft))
            }.padding(12)
            HSplitView {
                MacRouteTable(record: draft.record, selection: $presentation.selectedStopID)
                    .frame(minWidth: 360)
                if let id = model.selectedStopID {
                    MacRouteInspector(draft: draft, stopID: id, repository: repository)
                }
            }
        }.disabled(model.isBusy)
    }
    private func move(_ draft: RouteDraftController, offset: Int) { if let id = model.selectedStopID { draft.moveStop(id, offset: offset) } }
    private func canRemove(_ draft: RouteDraftController) -> Bool {
        guard let id = model.selectedStopID, let index = draft.record.stops.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0 && index < draft.record.stops.count - 1 && draft.record.stops.count > 3
    }
}

private struct MacRemoteRouteView: View {
    let record: RouteDayRecord
    let useRemote: () -> Void
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Маршрут на сервере · \(record.date) · \(record.workType.title)").font(.headline)
            Text("Пробег: \(record.distanceKm.map(String.init) ?? "—") км. Одометр: \(record.periodStartOdometer.map(String.init) ?? "—") км.")
            MacRouteTable(record: record, selection: $selection)
            HStack {
                Button("Использовать серверный маршрут", action: useRemote)
                Text("Заменит локальный черновик.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 760, height: 420)
    }
}
