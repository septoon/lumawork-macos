import SwiftUI
import EngineerCore

struct MacRouteTable: View {
    let record: RouteDayRecord
    @Binding var selection: String?
    var body: some View {
        Table(record.stops, selection: $selection) {
            TableColumn("Точка") { stop in
                Text(role(stop)).foregroundStyle(.secondary)
            }.width(55)
            TableColumn("Адрес") { stop in Text(stop.address.isEmpty ? "Адрес не указан" : stop.address).foregroundStyle(stop.address.isEmpty ? .secondary : .primary) }
                .width(min: 130, ideal: 250)
            TableColumn("Заявка") { stop in Text(stop.requestNumber) }.width(min: 75, ideal: 110)
            TableColumn("Статус") { stop in Text(stop.status.routeTitle) }.width(90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let stop = record.stops.first(where: { $0.id == id }), !stop.requestNumber.isEmpty {
                Button("Скопировать номер заявки") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(stop.requestNumber, forType: .string) }
            }
        }
    }
    private func role(_ stop: RouteStop) -> String {
        if stop.id == record.stops.first?.id { return "Начало" }
        if stop.id == record.stops.last?.id { return "Конец" }
        return String((record.stops.firstIndex(where: { $0.id == stop.id }) ?? 0))
    }
}

extension RouteStopStatus {
    var routeTitle: String {
        switch self { case .pending: "В процессе"; case .done: "Выполнена"; case .declined: "Отказ" }
    }
}
