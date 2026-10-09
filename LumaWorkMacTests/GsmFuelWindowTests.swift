import XCTest
@testable import EngineerCore

@MainActor final class GsmFuelWindowTests: XCTestCase {
    func testDiscardingProfileStillChecksRouteBeforeQuitAndCancelBlocksQuit() async throws {
        var profileDirty = true, routeDirty = true
        var prompts: [Bool] = []
        let entry = MacDraftRegistry.Entry(window: nil, hasDirty: { profileDirty || routeDirty }, save: { routeDirty = false }, discard: {
            if profileDirty { profileDirty = false } else { routeDirty = false }
        }, discardOnly: { profileDirty })
        let accepted = await MacDraftRegistry.resolve(entry, decision: { discardOnly in
            prompts.append(discardOnly)
            return discardOnly ? .alertFirstButtonReturn : .alertThirdButtonReturn
        }, failed: { _ in XCTFail() })
        XCTAssertFalse(accepted); XCTAssertEqual(prompts, [true, false]); XCTAssertTrue(routeDirty); XCTAssertFalse(profileDirty)
    }
    func testExistingProfileAndBoundVehicleDoNotOfferUnsupportedChanges() throws {
        var profile = GsmProfile.empty
        profile.employeeFullName = "Тест"; profile.employeeShortName = "Т.Т."; profile.employeeReportSignName = "Т.Т. Тест"
        profile.authorizedFullName = "Тест"; profile.authorizedShortName = "Т.Т."; profile.employeeJobTitle = "Инженер"
        profile.employeeCompany = "Тест"; profile.employeeAddress = "Тестовая, 1"; profile.employeePhone = "80000000000"
        profile.driverLicenseNumber = "fixture"; profile.fuelCardNumber = "fixture"; profile.carModel = "Original"
        profile.licensePlate = "TEST"; profile.fuelNorm = 9.4; profile.fuelTypes = ["АИ-95"]; profile.posProjectID = "fixture"
        profile.vehicleID = "bound"; profile.defaultStartOdometer = 100
        let model = MacGsmEditorModel(profile: profile, context: SessionContext(epoch: 1, userID: "fixture", simpleOneUserID: nil))
        model.startOdometer = "200"; model.draft.carModel = "Changed"
        let value = try model.record()
        XCTAssertEqual(value.defaultStartOdometer, 100); XCTAssertEqual(value.carModel, "Original")
    }
}
