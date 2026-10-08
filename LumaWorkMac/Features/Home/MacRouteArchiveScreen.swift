import SwiftUI
import EngineerCore

struct MacRouteArchiveScreen: View {
    let repository: RouteDayRepository
    @State var selectedDate: Date
    let openDay: (RouteDayRecord) -> Void
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss
    private var month: String { String(MacRouteDate.key(selectedDate).prefix(7)) }
    private var records: [RouteDayRecord] { repository.archive.filter { $0.date.hasPrefix(month) } }
    private var selectedRecord: RouteDayRecord? { records.first { $0.key.storageKey == selection } }
    private var totalKm: Double { records.reduce(0) { $0 + ($1.reportedDistanceKm ?? $1.distanceKm.map(Double.init) ?? 0) } }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Архив маршрутов").font(.title2)
                Spacer()
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }.help("Предыдущий месяц")
                DatePicker("Месяц", selection: $selectedDate, displayedComponents: .date).labelsHidden()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }.help("Следующий месяц")
                Button { Task { try? await repository.loadArchive(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(repository.isLoadingArchive).help("Обновить архив")
            }
            HStack {
                Text("\(month) · \(records.count) дней · \(totalKm.formatted(.number.precision(.fractionLength(0...1)))) км")
                    .foregroundStyle(.secondary)
                Spacer()
                if repository.isLoadingArchive { ProgressView().controlSize(.small) }
                if repository.archiveConnection == .offline { Label("Локальный архив", systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }
            Table(records, selection: $selection) {
                TableColumn("Дата") { Text($0.date) }.width(100)
                TableColumn("Работа") { Text($0.workType.title) }.width(55)
                TableColumn("Пробег, км") { Text(($0.reportedDistanceKm ?? $0.distanceKm.map(Double.init))?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") }.width(85)
                TableColumn("Одометр") { Text(($0.reportedPeriodStartOdometer ?? $0.periodStartOdometer).map(String.init) ?? "—") }.width(100)
                TableColumn("Маршрут") { Text($0.routeSummary ?? $0.stops.map(\.address).filter { !$0.isEmpty }.joined(separator: " → ")) }
            }
            .overlay {
                if records.isEmpty && !repository.isLoadingArchive {
                    ContentUnavailableView("Нет маршрутов за месяц", systemImage: "calendar", description: Text(repository.archiveConnection == .offline ? "Архив не обновлён: нет связи с сервером." : "Выберите другой месяц или отправьте маршрут дня."))
                }
            }
            if let error = repository.archiveError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if let record = selectedRecord { Text(record.requestNumbersSummary ?? "").foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Открыть день") { if let record = selectedRecord { openDay(record) } }.disabled(selectedRecord == nil)
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(minWidth: 820, minHeight: 480)
        .task { try? await repository.loadArchive() }
    }
    private func changeMonth(_ delta: Int) {
        if let value = Calendar(identifier: .gregorian).date(byAdding: .month, value: delta, to: selectedDate) { selectedDate = value; selection = nil }
    }
}

extension RouteDayRecord: @retroactive Identifiable {
    public var id: String { key.storageKey }
}
