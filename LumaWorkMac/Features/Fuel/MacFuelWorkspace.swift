import SwiftUI
import EngineerCore

@MainActor @Observable
final class MacFuelWorkspace {
    var selectedDate = Date()
    var selection: String?
    var search = ""
    var showsArchive = false
    var imports: MacFuelImport?
    var editor: MacFuelEditorModel?
    var profileEditor: MacGsmEditorModel?
    var isGsmPresented = false
    var error: String?
    var notice: String?
    var hasDirty: Bool { editor?.isDirty == true || profileEditor?.isDirty == true || imports?.hasDirty == true }
    func discardEditors() { editor = nil; profileEditor = nil; imports?.reset(); imports = nil }
    func reset() { discardEditors(); selection = nil; search = ""; showsArchive = false; isGsmPresented = false; error = nil; notice = nil }
}
@MainActor @Observable
final class MacFuelEditorModel: Identifiable {
    let id = UUID()
    let base: FuelRecord?
    let context: SessionContext
    private let initial: FuelEditorDraft
    var draft: FuelEditorDraft
    var isSaving = false
    var error: String?
    init(record: FuelRecord, isNew: Bool, context: SessionContext) {
        base = isNew ? nil : record; self.context = context
        initial = FuelEditorDraft(record: record); draft = initial
    }
    var isDirty: Bool { draft != initial }
}
@MainActor @Observable
final class MacGsmEditorModel: Identifiable {
    let id = UUID()
    let base: GsmProfile
    let context: SessionContext
    var draft: GsmProfile
    var fuelNorm: String
    var startOdometer: String
    private let initialNorm: String
    private let initialOdometer: String
    var isSaving = false
    var error: String?
    init(profile: GsmProfile, context: SessionContext) {
        base = profile; draft = profile; self.context = context
        initialNorm = String(profile.fuelNorm); fuelNorm = initialNorm
        initialOdometer = String(profile.defaultStartOdometer); startOdometer = initialOdometer
    }
    var isDirty: Bool { draft != base || fuelNorm != initialNorm || startOdometer != initialOdometer }
    var canEditInitialOdometer: Bool { base == .empty }
    var canEditVehicleFields: Bool { draft.vehicleID == nil }
    func record() throws -> GsmProfile {
        guard let norm = Double(fuelNorm.replacingOccurrences(of: ",", with: ".")), let odometer = canEditInitialOdometer ? Int(startOdometer) : base.defaultStartOdometer else { throw AppServiceError.message("Укажите корректные норму и одометр.") }
        var value = draft; value.fuelNorm = norm; value.defaultStartOdometer = odometer
        if base.vehicleID != nil, draft.vehicleID == base.vehicleID { value.carModel = base.carModel; value.licensePlate = base.licensePlate }
        _ = try GsmWire.profilePayload(value); return value
    }
}
