import SwiftUI
import EngineerCore

@MainActor @Observable
final class MacVehiclesWorkspace {
    var selection: String?
    var maintenanceSelection: String?
    var search = ""
    var vehicleEditor: MacVehicleEditorModel?
    var maintenanceEditor: MacMaintenanceEditorModel?
    var error: String?
    var notice: String?
    var hasDirty: Bool { vehicleEditor?.isDirty == true || maintenanceEditor?.isDirty == true }
    func discardEditors() { vehicleEditor = nil; maintenanceEditor = nil }
    func reset() { discardEditors(); selection = nil; maintenanceSelection = nil; search = ""; error = nil; notice = nil }
}
@MainActor @Observable
final class MacVehicleEditorModel: Identifiable {
    let id = UUID()
    let base: Vehicle?
    let context: SessionContext
    private let initial: VehicleDraft
    var draft: VehicleDraft
    var isSaving = false
    var error: String?
    init(base: Vehicle?, profile: UserProfileData?, context: SessionContext) {
        self.base = base; self.context = context
        let value = base.map { vehicle in VehicleDraft(vehicle: profile.map { vehicle.fillingMissingFields(from: $0) } ?? vehicle) } ?? profile.map(VehicleDraft.init(profile:)) ?? VehicleDraft()
        initial = value; draft = value
    }
    var isDirty: Bool { draft != initial }
}
@MainActor @Observable
final class MacMaintenanceEditorModel: Identifiable {
    struct Part: Identifiable, Equatable { let id = UUID(); var name = ""; var cost = "" }
    let id = UUID()
    let base: MaintenanceRecord?
    let context: SessionContext
    var vehicleID: String
    var date: Date
    var procedure: String
    var mileage: String
    var workCost: String
    var parts: [Part]
    var isSaving = false
    var error: String?
    private var initial: String = ""
    init(base: MaintenanceRecord?, vehicleID: String?, context: SessionContext) {
        self.base = base; self.context = context; self.vehicleID = base?.vehicleID ?? vehicleID ?? ""
        date = base.flatMap { MacRouteDate.date($0.date) } ?? Date(); procedure = base?.procedure ?? ""
        mileage = base.map { String($0.mileage) } ?? ""; workCost = base?.workCost.map { String($0) } ?? ""
        parts = base?.parts.map { Part(name: $0.name, cost: String($0.cost)) } ?? []
        initial = fingerprint
    }
    private var fingerprint: String { [vehicleID, MacRouteDate.key(date), procedure, mileage, workCost] .joined(separator: "\u{0}") + parts.map { $0.name + "\u{0}" + $0.cost }.joined(separator: "\u{1}") }
    var isDirty: Bool { fingerprint != initial }
    func input() throws -> MaintenanceRecordInput {
        guard let mileage = Int(mileage.trimmingCharacters(in: .whitespacesAndNewlines)), mileage >= 0 else { throw AppServiceError.message("Укажите целый неотрицательный пробег.") }
        func amount(_ raw: String) throws -> Double {
            guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { throw AppServiceError.message("Укажите корректную стоимость.") }; return value
        }
        let value = MaintenanceRecordInput(vehicleID: vehicleID.isEmpty ? nil : vehicleID, date: MacRouteDate.key(date), procedure: procedure, mileage: mileage,
                                           parts: try parts.map { MaintenancePart(name: $0.name, cost: try amount($0.cost)) },
                                           workCost: workCost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try amount(workCost))
        _ = try VehicleMaintenanceService.maintenancePayload(value); return value
    }
}
