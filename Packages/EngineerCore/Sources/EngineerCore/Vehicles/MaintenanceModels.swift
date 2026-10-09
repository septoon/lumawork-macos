import Foundation

public struct MaintenancePart: Codable, Hashable, Sendable {
    public init(name: String, cost: Double) { self.name = name; self.cost = cost }
    public var name: String
    public var cost: Double
}

public struct MaintenanceRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String?
    public var vehicleID: String?
    public var date: String
    public var procedure: String
    public var mileage: Int
    public var parts: [MaintenancePart]
    public var workCost: Double?
    public var totalCost: Double?

    public var stableID: String {
        id ?? "\(date)|\(procedure)|\(mileage)|\(parts.map(\.name).joined(separator: ","))|\(workCost ?? -1)"
    }
}

public struct MaintenanceRecordInput: Sendable {
    public init(vehicleID: String?, date: String, procedure: String, mileage: Int, parts: [MaintenancePart], workCost: Double?) {
        self.vehicleID = vehicleID; self.date = date; self.procedure = procedure; self.mileage = mileage; self.parts = parts; self.workCost = workCost
    }
    public var vehicleID: String?
    public var date: String
    public var procedure: String
    public var mileage: Int
    public var parts: [MaintenancePart]
    public var workCost: Double?
}
