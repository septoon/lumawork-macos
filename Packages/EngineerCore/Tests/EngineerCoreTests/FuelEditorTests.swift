import XCTest
@testable import EngineerCore
final class FuelEditorTests: XCTestCase {
    func testInvalidNumericTextCannotSilentlyRemoveOrRetainOldValue() throws {
        var editor = FuelEditorDraft(record: FuelRecord(id: "test", date: "2026-06-01", mileage: 100))
        editor.mileage = "не число"
        XCTAssertThrowsError(try editor.record())
        editor.mileage = "17,5"; let result = try editor.record()
        XCTAssertEqual(result.mileage, 17.5); XCTAssertEqual(result.id, "test")
        editor.mileage = ""; XCTAssertThrowsError(try editor.record())
    }
    func testAdjustmentSwitchDoesNotSendHiddenRefuelingFields() throws {
        var editor = FuelEditorDraft(record: FuelRecord(date: "2026-06-01", mileage: 100, liters: 20, fuelCost: 1520, fuelType: "АИ-95"))
        editor.recordType = .adjustment; editor.adjustmentKind = .debtDeduction; editor.amount = "76"; editor.liters = ""
        let record = try editor.record()
        XCTAssertNil(record.mileage); XCTAssertNil(record.fuelCost); XCTAssertNil(record.fuelType); XCTAssertEqual(record.amount, 76)
    }
}
