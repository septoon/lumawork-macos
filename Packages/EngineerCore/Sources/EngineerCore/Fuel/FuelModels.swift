import Foundation

public struct FuelRecord: Codable, Hashable, Sendable, Identifiable {
    public enum RecordType: String, Codable, Sendable { case fuel, adjustment }
    public enum AdjustmentKind: String, Codable, Sendable { case compensationPayment = "compensation_payment", debtDeduction = "debt_deduction" }
    public var id: String?
    public var recordType: RecordType
    public var adjustmentKind: AdjustmentKind?
    public var monthKey: String?
    public var amount: Double?
    public var carryoverDebtRub: Double?
    public var comment: String?
    public var date: String
    public var mileage: Double?
    public var liters: Double?
    public var fuelCost: Double?
    public var fuelType: String?
    public var fuelConsumptionRate: Double?
    public var source: String?
    public var sourceImportId: String?
    public init(id: String? = nil, recordType: RecordType = .fuel, adjustmentKind: AdjustmentKind? = nil, monthKey: String? = nil, amount: Double? = nil, carryoverDebtRub: Double? = nil, comment: String? = nil, date: String, mileage: Double? = nil, liters: Double? = nil, fuelCost: Double? = nil, fuelType: String? = nil, fuelConsumptionRate: Double? = nil, source: String? = nil, sourceImportId: String? = nil) {
        self.id = id; self.recordType = recordType; self.adjustmentKind = adjustmentKind; self.monthKey = monthKey
        self.amount = amount; self.carryoverDebtRub = carryoverDebtRub; self.comment = comment; self.date = date
        self.mileage = mileage; self.liters = liters; self.fuelCost = fuelCost; self.fuelType = fuelType
        self.fuelConsumptionRate = fuelConsumptionRate; self.source = source; self.sourceImportId = sourceImportId
    }
    public var stableID: String { id ?? "\(recordType.rawValue)|\(adjustmentKind?.rawValue ?? "")|\(monthKey ?? "")|\(date)|\(mileage ?? -1)|\(liters ?? -1)|\(fuelCost ?? -1)|\(fuelType ?? "")|\(amount ?? -1)" }
}

public struct FuelSummaryMonth: Hashable {
    public var key: String
    public var label: String
    public var totalMileage: Double
    public var totalLiters: Double
    public var fuelNorm: Double
    public var fuelCost: Double
    public var fuelDiff: Double
    public var diffLabel: String
    public var approvedRate: Double
    public var compensation: Double
    public var paidCompensation: Double
    public var debtDeductionAmount: Double
    public var debtDeductionLiters: Double
    public var effectiveDebtDeductionAmount: Double
    public var effectiveDebtDeductionLiters: Double
    public var effectiveAppliedCompensation: Double
    public var remainingCompensation: Double
    public var incomingCarryoverDebtRub: Double
    public var incomingCarryoverDebtLiters: Double
    public var monthCarryoverDebtRub: Double
    public var monthCarryoverDebtLiters: Double
    public var projectedDebtDeductionFromCarryover: Double
    public var projectedPayout: Double
    public var isCompensationClosed: Bool
    public var compensationStatusLabel: String
    public var adjustments: [FuelRecord]
}

public struct FuelSummaryTotals: Hashable {
    public var totalMileage: Double = 0
    public var totalLiters: Double = 0
    public var fuelNorm: Double = 0
    public var totalFuelCost: Double = 0
    public var totalCompensation: Double = 0
    public var totalPaidCompensation: Double = 0
    public var totalDebtDeductionAmount: Double = 0
    public var totalDebtDeductionLiters: Double = 0
    public var effectiveDebtDeductionAmount: Double = 0
    public var effectiveDebtDeductionLiters: Double = 0
    public var hasEstimatedDebtDeductionAmount = false
    public var hasEstimatedDebtDeductionLiters = false
    public var carryoverDebtRub: Double = 0
    public var carryoverDebtLiters: Double = 0
    public var netCompensation: Double = 0
    public var fuelDiff: Double = 0
    public var diffLabel: String = ""
    public var adjustedFuelDiff: Double = 0
    public var adjustedDiffLabel: String = ""
}

public struct FuelSummary: Hashable {
    public var monthly: [FuelSummaryMonth] = []
    public var totals = FuelSummaryTotals()
    public var explanation = ""
    public var hasData = false
}
