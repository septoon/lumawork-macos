import Foundation

public struct VehicleMaintenanceService {
    private let client: DomainHTTPClient
    public init(config: AppConfig, token: String) { client = DomainHTTPClient(config: config, token: token) }
    public func vehicles() async throws -> [Vehicle] {
        guard let row = try await client.request("api/v2/vehicles") as? [String: Any], let items = row["vehicles"] as? [Any] else { throw GsmFuelError.invalidResponse }
        let values = try items.map { raw in guard let value = Self.vehicle(raw) else { throw GsmFuelError.invalidResponse }; return value }
        guard Set(values.map(\.id)).count == values.count else { throw GsmFuelError.invalidResponse }
        return values
    }
    public func saveVehicle(_ draft: VehicleDraft, id: String?) async throws -> Vehicle {
        let path = try id.map { "api/v2/vehicles/" + (try DomainHTTPClient.id($0)) } ?? "api/v2/vehicles"
        let raw = try await client.request(path, method: id == nil ? "POST" : "PUT", body: draft.payload())
        guard let item = (raw as? [String: Any])?["vehicle"], let vehicle = Self.vehicle(item), id == nil || vehicle.id == id else { throw GsmFuelError.invalidResponse }
        return vehicle
    }
    public func maintenance() async throws -> [MaintenanceRecord] {
        guard let row = try await client.request("api/v2/maintenance") as? [String: Any], let records = row["records"] as? [Any] else { throw GsmFuelError.invalidResponse }
        let values = try records.map(Self.maintenanceRecord)
        guard Set(values.map(\.stableID)).count == values.count else { throw GsmFuelError.invalidResponse }
        return values.sorted { $0.date > $1.date }
    }
    public static func maintenancePayload(_ input: MaintenanceRecordInput) throws -> [String: Any] {
        guard RequestsPolicy.date(input.date) != nil, !input.procedure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.mileage >= 0, input.parts.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.cost.isFinite && $0.cost >= 0 }),
              input.workCost.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw AppServiceError.message("Проверьте дату, процедуру, пробег и стоимость обслуживания.") }
        let partsCost = input.parts.reduce(0) { $0 + $1.cost }
        guard partsCost.isFinite, (partsCost + (input.workCost ?? 0)).isFinite else { throw AppServiceError.message("Сумма обслуживания слишком велика.") }
        var body: [String: Any] = ["date": input.date, "procedure": input.procedure, "mileage": input.mileage,
                                  "parts": input.parts.map { ["name": $0.name, "cost": $0.cost] }]
        body["vehicleId"] = input.vehicleID as Any? ?? NSNull()
        if !input.parts.isEmpty { body["partsCost"] = partsCost }
        body["workCost"] = input.workCost as Any? ?? NSNull()
        return body
    }
    public func saveMaintenance(_ input: MaintenanceRecordInput, id: String?) async throws -> MaintenanceRecord {
        let path = try id.map { "api/v2/maintenance/" + (try DomainHTTPClient.id($0)) } ?? "api/v2/maintenance"
        let raw = try await client.request(path, method: id == nil ? "POST" : "PUT", body: Self.maintenancePayload(input))
        let record = try Self.maintenanceRecord(raw as Any)
        guard record.id != nil, id == nil || record.id == id else { throw GsmFuelError.invalidResponse }
        return record
    }
    public func deleteMaintenance(_ id: String) async throws { _ = try await client.request("api/v2/maintenance/" + DomainHTTPClient.id(id), method: "DELETE") }
    private static func maintenanceRecord(_ raw: Any) throws -> MaintenanceRecord {
        guard let row = raw as? [String: Any] else { throw GsmFuelError.invalidResponse }
        var parts = try (row["parts"] as? [[String: Any]] ?? []).map { part -> MaintenancePart in
            let name = stringValue(part["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let cost = doubleValue(part["cost"]), cost.isFinite, cost >= 0 else { throw GsmFuelError.invalidResponse }
            return MaintenancePart(name: name, cost: cost)
        }
        if parts.isEmpty, let legacy = doubleValue(row["partsCost"]), legacy.isFinite, legacy >= 0 { parts = [.init(name: "Запчасти", cost: legacy)] }
        let work = doubleValue(row["workCost"])
        let total = doubleValue(row["totalCost"]) ?? (parts.isEmpty && work == nil ? nil : parts.reduce(0) { $0 + $1.cost } + (work ?? 0))
        let date = stringValue(row["date"]), procedure = stringValue(row["procedure"])
        guard date.count == 10, RequestsPolicy.date(date) != nil, !procedure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mileage = Self.integer(row["mileage"]), mileage >= 0,
              work.map({ $0.isFinite && $0 >= 0 }) ?? true, total.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw GsmFuelError.invalidResponse }
        return MaintenanceRecord(id: UserProfileData.clean(stringValue(row["id"])) ?? UserProfileData.clean(stringValue(row["_id"])),
                                 vehicleID: UserProfileData.clean(stringValue(row["vehicleId"])), date: date,
                                 procedure: procedure, mileage: mileage, parts: parts, workCost: work, totalCost: total)
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let value = doubleValue(raw), value.isFinite else { return nil }
        return Int(exactly: value)
    }
    static func vehicle(_ raw: Any) -> Vehicle? {
        guard let dictionary = (raw as? [String: Any]) else { return nil }
        let id = stringValue(dictionary["id"])
        guard !id.isEmpty else { return nil }
        let settingsRaw = (dictionary["gsmSettings"] as? [String: Any])
        let settings = settingsRaw.map {
            Vehicle.GsmSettings(
                fuelNorm: doubleValue($0["fuelNorm"]) ?? 0,
                fuelType: stringValue($0["fuelType"]),
                defaultStartOdometer: Self.integer($0["defaultStartOdometer"]) ?? 0,
                reportStartMonth: stringValue($0["reportStartMonth"]).nilIfBlank ?? "2026-04"
            )
        }
        return Vehicle(
            id: id,
            make: stringValue(dictionary["make"]).nilIfBlank,
            model: stringValue(dictionary["model"]).nilIfBlank,
            generation: stringValue(dictionary["generation"]).nilIfBlank,
            year: Self.integer(dictionary["year"]),
            bodyType: stringValue(dictionary["bodyType"]).nilIfBlank,
            colorName: stringValue(dictionary["colorName"]).nilIfBlank,
            customName: stringValue(dictionary["customName"]).nilIfBlank,
            licensePlate: stringValue(dictionary["licensePlate"]).nilIfBlank,
            vin: stringValue(dictionary["vin"]).nilIfBlank,
            sts: stringValue(dictionary["sts"]).nilIfBlank,
            pts: stringValue(dictionary["pts"]).nilIfBlank,
            engineVolumeCm3: Self.integer(dictionary["engineVolumeCm3"]),
            enginePowerHp: Self.integer(dictionary["enginePowerHp"]),
            currentMileageKm: Self.integer(dictionary["currentMileageKm"]),
            isPrimary: dictionary["isPrimary"] as? Bool ?? false,
            imageURL: URL(string: stringValue(dictionary["imageUrl"])),
            imageStatus: stringValue(dictionary["imageStatus"]),
            gsmSettings: settings,
            documents: (dictionary["documents"] as? [Any] ?? []).compactMap { Self.document($0) }
        )
    }

    private static func document(_ raw: Any) -> VehicleDocument? {
        guard let dictionary = (raw as? [String: Any]) else { return nil }
        let id = stringValue(dictionary["id"])
        let fileName = stringValue(dictionary["fileName"])
        guard !id.isEmpty, !fileName.isEmpty else { return nil }
        return VehicleDocument(
            id: id,
            kind: VehicleDocumentKind(rawValue: stringValue(dictionary["kind"])) ?? .other,
            fileName: fileName,
            mimeType: stringValue(dictionary["mimeType"]),
            sizeBytes: Self.integer(dictionary["sizeBytes"]) ?? 0,
            createdAt: stringValue(dictionary["createdAt"])
        )
    }
}

private extension String { var nilIfBlank: String? { UserProfileData.clean(self) } }
