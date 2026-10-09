import Foundation

public struct SalaryEntry: Codable, Hashable, Sendable {
    public var id: String?
    public var date: String
    public var baseSalary: Double
    public var weekendPay: Double
    public var periodMonth: String?
    public var amount: Double?
    public var kind: SalaryPaymentKind?
    public var comment: String?
    public init(id: String? = nil, date: String, baseSalary: Double = 0, weekendPay: Double = 0, periodMonth: String? = nil, amount: Double? = nil, kind: SalaryPaymentKind? = nil, comment: String? = nil) {
        self.id = id; self.date = date; self.baseSalary = baseSalary; self.weekendPay = weekendPay; self.periodMonth = periodMonth; self.amount = amount; self.kind = kind; self.comment = comment
    }
    public var stableID: String { id ?? "\(date)|\(baseSalary)|\(weekendPay)|\(periodMonth ?? "")|\(amount ?? 0)|\(kind?.rawValue ?? "")|\(comment ?? "")" }
    public static let netPaymentStartDate = "2026-05-13"
    public var accrualMonthKey: String { periodMonth ?? String(date.prefix(7)) }
    public var usesNetPaymentAmount: Bool { amount != nil || date >= Self.netPaymentStartDate }
    public var netPaymentAmount: Double { amount ?? baseSalary + weekendPay }
    public var paymentKind: SalaryPaymentKind { kind ?? (usesNetPaymentAmount && (Int(date.suffix(2)) ?? 0) > 10 ? .advance : .salary) }
    public static func previousMonthKey(from key: String) -> String? {
        guard GsmWire.isValidMonth(key) else { return nil }
        let parts = key.split(separator: "-"); guard let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return month == 1 ? "\(year - 1)-12" : String(format: "%04d-%02d", year, month - 1)
    }
    public static func inferredPeriodMonth(for date: String) -> String {
        let month = String(date.prefix(7))
        if date >= netPaymentStartDate, let day = Int(date.suffix(2)), day <= 10 { return previousMonthKey(from: month) ?? month }
        return month
    }
}
public enum SalaryCalculations {
    public static let taxRate = 0.13
    public static func payout(for entry: SalaryEntry) -> Double {
        if entry.usesNetPaymentAmount { return entry.netPaymentAmount }
        let gross = entry.baseSalary + entry.weekendPay
        return gross - floor(gross * taxRate)
    }
}
public struct SalaryMonth: Identifiable, Hashable, Sendable {
    public var id: String { month }
    public let month: String
    public let entries: [SalaryEntry]
    public var total: Double { entries.reduce(0) { $0 + SalaryCalculations.payout(for: $1) } }
    public static func group(_ entries: [SalaryEntry]) -> [SalaryMonth] {
        Dictionary(grouping: entries, by: \.accrualMonthKey).map { SalaryMonth(month: $0.key, entries: $0.value.sorted { ($0.date, $0.stableID) > ($1.date, $1.stableID) }) }.sorted { $0.month > $1.month }
    }
}
