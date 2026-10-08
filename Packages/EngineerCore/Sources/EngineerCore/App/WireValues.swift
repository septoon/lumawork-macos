import Foundation

public enum SalaryPaymentKind: String, CaseIterable, Codable, Hashable {
    case advance
    case salary
    case weekend
    case gsm
    case other

    public var title: String {
        switch self {
        case .advance:
            return "Аванс"
        case .salary:
            return "Зарплата"
        case .weekend:
            return "Работа в выходной"
        case .gsm:
            return "Компенсация ГСМ"
        case .other:
            return "Другое"
        }
    }
}

public enum RouteWorkType: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case pos = "POS"
    case arm = "ARM"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pos:
            return "POS"
        case .arm:
            return "АРМ"
        }
    }

    public func storageKey(for date: String) -> String {
        self == .pos ? date : "\(date)|\(rawValue)"
    }
}

public enum RouteStopStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case pending
    case done
    case declined
}
