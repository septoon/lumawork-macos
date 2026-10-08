import SwiftUI
import MapKit
import EngineerCore

struct MacRouteMapView: View {
    let model: MacRouteWorkspace
    let draft: RouteDraftController
    let repository: RouteDayRepository
    let coordinator: EngineerApplicationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: RouteMapSnapshot?
    @State private var source: RouteDayRecord?
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedIndex = 0
    @State private var isLoading = false
    @State private var isUpdatingPoint = false
    @State private var isEditing = false
    @State private var remember = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var error: String?
    @State private var loadID = UUID()
    private var plan: RouteMapPlan { repository.mapPlan(for: draft.record) }
    private var canEdit: Bool { model.draft === draft && !model.isBusy && !isUpdatingPoint && coordinator.context != nil }
    private var coordinate: AppleRouteCoordinate? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")), let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let value = AppleRouteCoordinate(latitude: lat, longitude: lon)
        return value.isValid ? value : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Карта маршрута · \(draft.record.date) · \(draft.record.workType.title)").font(.headline)
                Spacer()
                Button("Показать весь маршрут") { position = .automatic }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if let snapshot, snapshot.hasGeometry {
                routeMap(snapshot)
            } else {
                ContentUnavailableView("Карта маршрута", systemImage: "map", description: Text(isLoading ? "Определяем адреса и строим автомобильный маршрут…" : error ?? "Заполните адреса точек и повторите расчёт."))
            }
            Divider()
            controls
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 700)
        .task(id: plan) { await load() }
        .onChange(of: selectedIndex) { _, _ in restoreCoordinates() }
    }
    private func routeMap(_ snapshot: RouteMapSnapshot) -> some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(snapshot.stopCoordinates.indices, id: \.self) { index in
                    Annotation(title(index), coordinate: snapshot.stopCoordinates[index].location) {
                        Button {
                            selectedIndex = index
                        } label: {
                            Image(systemName: index == selectedIndex ? "mappin.circle.fill" : "mappin.circle")
                                .font(.title)
                                .foregroundStyle(snapshot.unverifiedStopIndices.contains(index) ? Color.orange : Color.accentColor)
                                .padding(4)
                        }.buttonStyle(.plain).help(snapshot.addresses[index])
                    }
                }
                ForEach(snapshot.legs.indices, id: \.self) { i in
                    if snapshot.legs[i].coordinates.count > 1 {
                        MapPolyline(coordinates: snapshot.legs[i].coordinates.map(\.location)).stroke(Color.accentColor, lineWidth: 4)
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { location in
                guard isEditing, canEdit, let value = proxy.convert(location, from: .local) else { return }
                applyCoordinate(AppleRouteCoordinate(latitude: value.latitude, longitude: value.longitude))
            }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isLoading { ProgressView().controlSize(.small); Text("Рассчитываем маршрут…").foregroundStyle(.secondary) }
                else if let snapshot, snapshot.hasGeometry, snapshot.matches(plan), !snapshot.routingIncomplete {
                    Text("Пробег через Apple Maps: \(snapshot.distanceKm) км").monospacedDigit()
                }
                Spacer()
                Button("Повторить расчёт") { Task { await load(force: true) } }.disabled(isLoading || isUpdatingPoint)
                Button("Применить пробег") {
                    if let snapshot, let source, canEdit, draft.applyMapDistance(snapshot, source: source, plan: plan) {
                        model.notice = "Пробег применён к черновику. Сохраните или отправьте маршрут."; dismiss()
                    } else {
                        error = "Маршрут изменился. Повторите расчёт перед применением пробега."
                    }
                }.disabled(!canEdit || isLoading || snapshot?.matches(plan) != true || snapshot?.canApplyDistance != true)
            }
            if let error = error ?? snapshot?.failureDescription { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if snapshot?.unverifiedStopIndices.isEmpty == false {
                Label("Проверьте оранжевые точки. Подтвердите расположение перед применением пробега.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Picker("Точка", selection: $selectedIndex) {
                ForEach(draft.record.stops.indices, id: \.self) { i in Text("\(title(i)): \(draft.record.stops[i].address)").tag(i) }
            }.disabled(!canEdit)
            HStack {
                Toggle("Уточнить на карте", isOn: $isEditing).toggleStyle(.checkbox)
                Toggle("Запомнить для этого адреса", isOn: $remember).toggleStyle(.checkbox)
                Spacer()
                Button("Подтвердить точку") {
                    if let snapshot, snapshot.stopCoordinates.indices.contains(selectedIndex) { applyCoordinate(snapshot.stopCoordinates[selectedIndex]) }
                }.disabled(snapshot?.matches(plan) != true || isLoading)
                Button("Сбросить исправление") { applyCoordinate(nil) }
            }.disabled(!canEdit)
            HStack {
                TextField("Широта", text: $latitude).frame(width: 160)
                TextField("Долгота", text: $longitude).frame(width: 160)
                Button("Применить координаты") { applyCoordinate(coordinate) }.disabled(coordinate == nil)
                if isEditing { Text("Щёлкните по карте, чтобы переместить выбранную точку.").font(.caption).foregroundStyle(.secondary) }
            }.disabled(!canEdit)
        }.padding(12)
    }
    private func title(_ i: Int) -> String { i == 0 ? "Старт" : i == draft.record.stops.count - 1 ? "Финиш" : "Точка \(i)" }
    private func load(force: Bool = false) async {
        let id = UUID(); loadID = id
        let input = plan; let original = draft.record
        guard let context = coordinator.context else { return }
        isLoading = true; error = nil; snapshot = nil; source = nil
        defer { if loadID == id { isLoading = false } }
        do {
            let cached = try await repository.prepareMap(for: input)
            try Task.checkCancellation()
            guard coordinator.accepts(context), plan == input, loadID == id else { return }
            snapshot = cached; source = original
            let result = try await repository.calculateMap(for: input, force: force)
            try Task.checkCancellation()
            guard coordinator.accepts(context), plan == input, loadID == id, model.draft === draft else { return }
            snapshot = result; source = original
            if !result.stopCoordinates.indices.contains(selectedIndex) { selectedIndex = result.unverifiedStopIndices.first ?? 0 }
            restoreCoordinates()
        } catch {
            if !AppErrorClassification.isCancellation(error), coordinator.accepts(context), loadID == id { self.error = error.localizedDescription }
        }
    }
    private func restoreCoordinates() {
        guard let snapshot, snapshot.stopCoordinates.indices.contains(selectedIndex) else { latitude = ""; longitude = ""; return }
        let value = snapshot.stopCoordinates[selectedIndex]
        latitude = String(value.latitude); longitude = String(value.longitude)
    }
    private func applyCoordinate(_ coordinate: AppleRouteCoordinate?) {
        guard canEdit, draft.record.stops.indices.contains(selectedIndex), coordinate?.isValid != false, let context = coordinator.context else { return }
        let original = draft.record; let stop = original.stops[selectedIndex]; let shouldRemember = remember
        isUpdatingPoint = true
        Task {
            defer { isUpdatingPoint = false }
            do {
                if shouldRemember || coordinate == nil { try await repository.rememberMapCoordinate(coordinate, for: stop.address) }
                try Task.checkCancellation()
                guard coordinator.accepts(context), model.draft === draft, draft.record.key == original.key, draft.record.stops == original.stops, !model.isBusy else { return }
                draft.updateStop(stop.id, coordinate: .some(coordinate)); error = nil; isEditing = false
            } catch { if coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
