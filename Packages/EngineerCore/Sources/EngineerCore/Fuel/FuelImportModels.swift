import Foundation

public struct FuelImportUpload: Encodable, Sendable {
    public init(fileName: String, dataBase64: String) { self.fileName = fileName; self.dataBase64 = dataBase64 }
    public let fileName: String
    public let dataBase64: String
}

public struct FuelImportEntry: Decodable, Hashable, Identifiable, Sendable {
    public let row: Int
    public let date: String?
    public let fuelType: String?
    public let liters: Double?
    public let cost: Double?

    public var id: Int { row }

    public var isIncomplete: Bool {
        date == nil || fuelType == nil || liters == nil || cost == nil
    }
}

public struct FuelImportTypeTotal: Decodable, Hashable, Identifiable, Sendable {
    public let fuelType: String
    public let liters: Double
    public let cost: Double

    public var id: String { fuelType }
}

public struct FuelImportPreviewItem: Decodable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case warning
        case duplicate
        case conflict
        case replaceable
        case error
    }

    public let id: String
    public let fileName: String
    public let fileHash: String
    public let status: Status
    public let period: String?
    public let entries: [FuelImportEntry]
    public let totalsByFuelType: [FuelImportTypeTotal]
    public let totalLiters: Double
    public let totalCost: Double
    public let mileage: Double?
    public let carModel: String?
    public let fuelNorm: Double?
    public let worksheets: [String]
    public let reportFormatVersion: Int
    public let importerVersion: String
    public let warnings: [String]
    public let errors: [String]
    public let existingImportId: String?
}

public struct FuelImportEntryCorrection: Hashable, Identifiable, Sendable {
    public var id: Int { row }
    public let row: Int
    public var date: String
    public var fuelType: String
    public var liters: String
    public var cost: String

    public init(entry: FuelImportEntry) {
        row = entry.row
        date = entry.date ?? ""
        fuelType = entry.fuelType ?? ""
        liters = entry.liters.map { String($0) } ?? ""
        cost = entry.cost.map { String($0) } ?? ""
    }

    public var dictionary: [String: Any] {
        var result: [String: Any] = ["row": row]
        let normalizedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDate.isEmpty { result["date"] = normalizedDate }
        let normalizedFuelType = fuelType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFuelType.isEmpty { result["fuelType"] = normalizedFuelType }
        if let value = parseNumber(liters) { result["liters"] = value }
        if let value = parseNumber(cost) { result["cost"] = value }
        return result
    }

    private func parseNumber(_ value: String) -> Double? {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }; return number
    }
}

public struct FuelImportCorrection: Hashable, Sendable {
    public let fileHash: String
    public var period: String?
    public var entries: [FuelImportEntryCorrection]

    public init(item: FuelImportPreviewItem) {
        fileHash = item.fileHash
        period = item.period
        entries = item.entries.map(FuelImportEntryCorrection.init)
    }

    public var dictionary: [String: Any] {
        var result: [String: Any] = [
            "fileHash": fileHash,
            "entries": entries.map(\.dictionary)
        ]
        if let period { result["period"] = period }
        return result
    }
}

public struct FuelImportCommitResponse: Decodable, Sendable {
    public struct Result: Decodable, Identifiable, Sendable {
        public let fileName: String
        public let period: String?
        public let status: String
        public let message: String
        public let refuelCount: Int

        public var id: String { "\(fileName)|\(period ?? "")|\(status)" }
    }

    public let importedMonths: Int
    public let skippedMonths: Int
    public let importedRefuels: Int
    public let totalLiters: Double
    public let totalCost: Double
    public let results: [Result]
}
