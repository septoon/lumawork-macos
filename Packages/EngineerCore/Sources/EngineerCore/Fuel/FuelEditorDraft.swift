import Foundation

public struct FuelEditorDraft: Equatable {
    public var recordType: FuelRecord.RecordType
    public var adjustmentKind: FuelRecord.AdjustmentKind
    public var date: String
    public var month: String
    public var mileage: String
    public var liters: String
    public var cost: String
    public var amount: String
    public var carryover: String
    public var comment: String
    public var fuelType: String
    private let source: FuelRecord
    public init(record: FuelRecord) {
        source = record; recordType = record.recordType; adjustmentKind = record.adjustmentKind ?? .compensationPayment
        date = record.date; month = record.monthKey ?? String(record.date.prefix(7)); mileage = record.mileage.map(String.init(describing:)) ?? ""
        liters = record.liters.map(String.init(describing:)) ?? ""; cost = record.fuelCost.map(String.init(describing:)) ?? ""
        amount = record.amount.map(String.init(describing:)) ?? ""; carryover = record.carryoverDebtRub.map(String.init(describing:)) ?? ""
        comment = record.comment ?? ""; fuelType = record.fuelType ?? ""
    }
    public func record() throws -> FuelRecord {
        func number(_ text: String, label: String) throws -> Double? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard let parsed = Double(value.replacingOccurrences(of: ",", with: ".")), parsed.isFinite, parsed >= 0 else { throw AppServiceError.message("Некорректное поле: " + label) }
            return parsed
        }
        let record = try FuelRecord(id: source.id, recordType: recordType,
                                   adjustmentKind: recordType == .adjustment ? adjustmentKind : nil,
                                   monthKey: recordType == .adjustment ? month : nil,
                                   amount: recordType == .adjustment ? number(amount, label: "Сумма корректировки") : nil,
                                   carryoverDebtRub: recordType == .adjustment && adjustmentKind == .debtDeduction ? number(carryover, label: "Остаток долга") : nil,
                                   comment: comment.nonempty, date: date,
                                   mileage: recordType == .fuel ? number(mileage, label: "Пробег") : nil,
                                   liters: recordType == .fuel || adjustmentKind == .debtDeduction ? number(liters, label: "Литры") : nil,
                                   fuelCost: recordType == .fuel ? number(cost, label: "Стоимость") : nil,
                                   fuelType: recordType == .fuel ? fuelType.nonempty : nil)
        _ = try FuelWire.payload(record); return record
    }
}
