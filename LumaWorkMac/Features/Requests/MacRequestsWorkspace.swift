import Foundation
import Observation
import EngineerCore

struct MacRequestRow: Identifiable, Sendable {
    let record: SimpleOneRequestRecord
    var id: String { record.id }
    let searchText: String
    let date: Date?
    let sortDate: Date
    let status: String
    let isWarehouse: Bool
    init(_ record: SimpleOneRequestRecord) {
        self.record = record; searchText = record.searchText
        date = RequestsPolicy.date(RequestsPolicy.effectiveTime(record))
        sortDate = record.source == .active ? record.registeredDate ?? .distantPast : date ?? .distantPast
        status = RequestsPolicy.multicardStatus(record); isWarehouse = RequestsPolicy.isWarehouse(record)
    }
}

enum MacRequestStatusFilter: String, CaseIterable, Identifiable {
    case all, available, inProgress, waiting
    var id: String { rawValue }
    var title: String { switch self { case .all: "Все"; case .available: "Доступные"; case .inProgress: "В работе"; case .waiting: "В ожидании" } }
    func contains(_ raw: String) -> Bool {
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return switch self { case .all: true; case .available: status == "работа в приложении"; case .waiting: status == "в ожидании"; case .inProgress: status != "работа в приложении" && status != "в ожидании" }
    }
}

@MainActor @Observable
final class MacRequestsWorkspace {
    var scope = RequestsScope.active
    var search = ""
    var month = Date()
    var allDates = false
    var status = MacRequestStatusFilter.all
    var selection: String?
    var prepared: [MacRequestRow] = []
    var detail: SimpleOneRequestRecord?
    var detailError: String?
    var isLoadingDetail = false
    var browserRecord: SimpleOneRequestRecord?
    func reset() { prepared = []; selection = nil; detail = nil; detailError = nil; isLoadingDetail = false; browserRecord = nil; search = "" }
}
