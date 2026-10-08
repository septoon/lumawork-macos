import SwiftUI
import EngineerCore

struct MacRouteInspector: View {
    let draft: RouteDraftController
    let stopID: String
    let repository: RouteDayRepository
    @State private var latitude = ""
    @State private var longitude = ""
    private var stop: RouteStop? { draft.record.stops.first { $0.id == stopID } }
    private var isEdge: Bool { stopID == draft.record.stops.first?.id || stopID == draft.record.stops.last?.id }
    private var coordinate: AppleRouteCoordinate? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")), let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let result = AppleRouteCoordinate(latitude: lat, longitude: lon)
        return result.isValid ? result : nil
    }
    var body: some View {
        Form {
            if let stop {
                Section("Точка маршрута") {
                    TextField("Адрес", text: field(\.address) { draft.updateStop(stopID, address: $0) }, axis: .vertical)
                        .lineLimit(2...5)
                    if isEdge {
                        Menu("Выбрать адрес") {
                            Button("Склад") { draft.updateStop(stopID, address: repository.settings.startAddress) }
                            Button("Дом") { draft.updateStop(stopID, address: repository.settings.homeAddress) }
                                .disabled(repository.settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else if draft.record.workType == .arm, !repository.officeAddresses.isEmpty {
                        Menu("Отделение") {
                            ForEach(repository.officeAddresses, id: \.self) { address in
                                Button(address) { draft.updateStop(stopID, address: address) }
                            }
                        }
                    }
                    TextField("№ заявки", text: field(\.requestNumber) { draft.updateStop(stopID, requestNumber: $0) })
                    TextField("Организация", text: field(\.org) { draft.updateStop(stopID, org: $0) })
                    TextField("TID", text: field(\.tid) { draft.updateStop(stopID, tid: $0) })
                    TextField("Причина выезда", text: field(\.reason) { draft.updateStop(stopID, reason: $0) }, axis: .vertical)
                    Picker("Статус", selection: Binding(get: { self.stop?.status ?? .pending }, set: { draft.updateStop(stopID, status: $0) })) {
                        ForEach(RouteStopStatus.allCases, id: \.self) { Text($0.routeTitle).tag($0) }
                    }.disabled(isEdge)
                    if stop.status == .declined {
                        TextField("Причина отказа", text: field(\.declineReason) { draft.updateStop(stopID, declineReason: $0) }, axis: .vertical)
                    }
                }
                Section("Уточнение координат") {
                    TextField("Широта", text: $latitude)
                    TextField("Долгота", text: $longitude)
                    HStack {
                        Button("Применить") { draft.updateStop(stopID, coordinate: .some(coordinate)) }.disabled(coordinate == nil)
                        Button("Сбросить") { draft.updateStop(stopID, coordinate: .some(nil)); latitude = ""; longitude = "" }
                            .disabled(stop.coordinateOverride == nil)
                    }
                    if stop.coordinateOverride != nil { Text("Координаты заданы вручную.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: restoreCoordinates)
        .onChange(of: stopID) { _, _ in restoreCoordinates() }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
    }
    private func field(_ key: KeyPath<RouteStop, String>, update: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { stop?[keyPath: key] ?? "" }, set: update)
    }
    private func restoreCoordinates() {
        latitude = stop?.coordinateOverride.map { String($0.latitude) } ?? ""
        longitude = stop?.coordinateOverride.map { String($0.longitude) } ?? ""
    }
}
