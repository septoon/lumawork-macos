import Foundation

public enum ProfileWorkCategory: String, CaseIterable, Identifiable, Sendable {
    case portable, stationary, integration, fiscal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .portable: "Переносные"
        case .stationary: "Стационарные"
        case .integration: "Интеграции"
        case .fiscal: "Кассы"
        }
    }

    init?(terminalType: String) {
        switch terminalType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "portable_pos", "universal_pos": self = .portable
        case "stat_pos": self = .stationary
        case "intel_pin": self = .integration
        case "fiscal_pos": self = .fiscal
        default: return nil
        }
    }
}

public enum ProfileWorkOperation: String, CaseIterable, Identifiable, Sendable {
    case install, replacement, serviceStd, dismounting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .install: "Установки"
        case .replacement: "Замены"
        case .serviceStd: "Сервис"
        case .dismounting: "Демонтаж"
        }
    }
}

public struct ProfileCompletedWorkStatistics {
    public struct CategorySummary: Identifiable {
        public let category: ProfileWorkCategory
        public var counts: [ProfileWorkOperation: Int] = [:]
        public var id: ProfileWorkCategory { category }
        public var total: Int { counts.values.reduce(0, +) }

        public var operations: [ProfileWorkOperation] {
            ProfileWorkOperation.allCases.filter {
                $0 != .dismounting || counts[$0, default: 0] > 0
            }
        }
    }

    public let categories: [CategorySummary]

    public init(records: [SimpleOneRequestRecord]) {
        self.init(archiveRecords: records.map(ClosedRequestProjection.closedRequestRecord(from:)))
    }

    private init(archiveRecords records: [ClosedRequestRecord]) {
        var counts: [ProfileWorkCategory: [ProfileWorkOperation: Int]] = [:]
        var seen = Set<String>()
        for record in records {
            guard record.isCompletedWithVisit,
                  let operation = ProfileWorkOperation(rawValue: record.requestType.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let category = Self.category(for: record, operation: operation) else { continue }
            let requestNumber = record.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestNumber.isEmpty, seen.insert(requestNumber).inserted else { continue }
            counts[category, default: [:]][operation, default: 0] += 1
        }
        categories = ProfileWorkCategory.allCases.map {
            CategorySummary(category: $0, counts: counts[$0] ?? [:])
        }
    }

    private static func category(for record: ClosedRequestRecord, operation: ProfileWorkOperation) -> ProfileWorkCategory? {
        let labels = operation == .dismounting
            ? ["Тип демонтируемого ТО", "Тип устанавливаемого ТО", "Тип терминала"]
            : ["Тип устанавливаемого ТО", "Тип терминала"]
        for label in labels {
            if let value = record.infoFields.first(where: {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                    .caseInsensitiveCompare(label) == .orderedSame
            })?.value, let category = ProfileWorkCategory(terminalType: value) {
                return category
            }
        }
        return nil
    }
}
