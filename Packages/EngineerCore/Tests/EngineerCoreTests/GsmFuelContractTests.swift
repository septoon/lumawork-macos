import XCTest
@testable import EngineerCore

func gsmFuelFixture() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "fuel-gsm", withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}
func fixtureFuelRecords() throws -> [FuelRecord] { try FuelWire.records(gsmFuelFixture()) }
func fixtureGsmProfile() throws -> GsmProfile { try GsmWire.profile(gsmFuelFixture()).profile }
final class GsmFuelContractTests: XCTestCase {
    func testFuelUppercaseNumericStringsAndAdjustmentsPreserveServerContract() throws {
        let records = try fixtureFuelRecords()
        XCTAssertEqual(records[0].mileage, 100); XCTAssertEqual(records[0].fuelConsumptionRate, 10)
        XCTAssertEqual(records[1].adjustmentKind, .compensationPayment); XCTAssertEqual(records[2].adjustmentKind, .debtDeduction)
        let payload = try FuelWire.payload(records[2])
        XCTAssertEqual(payload["recordType"] as? String, "adjustment")
        XCTAssertEqual(payload["adjustmentKind"] as? String, "debt_deduction")
        XCTAssertEqual(payload["carryoverDebtRub"] as? Double, 76)
        XCTAssertNil(payload["source"]); XCTAssertNil(payload["fuelConsumptionRate"])
        XCTAssertThrowsError(try FuelWire.records(["unexpected": true]))
    }
    func testFuelValidationSeparatesMileageAndRefuelingFromApril() throws {
        var value = FuelRecord(date: "2026-04-01", mileage: 100)
        XCTAssertNoThrow(try FuelWire.payload(value))
        value.liters = 5; XCTAssertThrowsError(try FuelWire.payload(value))
        value.fuelCost = 380; value.fuelType = "АИ-95"; XCTAssertNoThrow(try FuelWire.payload(value))
        value.liters = .nan; XCTAssertThrowsError(try FuelWire.payload(value))
        value.liters = 5; value.date = "2026-02-30"; XCTAssertThrowsError(try FuelWire.payload(value))
        value.date = "2026-03-31"; value.fuelType = nil; XCTAssertNoThrow(try FuelWire.payload(value))
        var adjustment = FuelRecord(recordType: .adjustment, adjustmentKind: .compensationPayment, date: "2026-07-01")
        XCTAssertThrowsError(try FuelWire.payload(adjustment)); adjustment.amount = 100
        XCTAssertNoThrow(try FuelWire.payload(adjustment)); adjustment.monthKey = "2026-13"
        XCTAssertThrowsError(try FuelWire.payload(adjustment))
    }
    func testSummaryNormCompensationEstimatedDebtAndCarryoverMatchIOS() throws {
        let records = try fixtureFuelRecords()
        let summary = FuelSummaryCalculator.build(records: records)
        let month = try XCTUnwrap(summary.monthly.first)
        XCTAssertEqual(month.fuelNorm, 10); XCTAssertEqual(month.compensation, 500)
        XCTAssertEqual(month.effectiveDebtDeductionAmount, 152); XCTAssertEqual(month.projectedPayout, 248)
        XCTAssertEqual(summary.totals.adjustedFuelDiff, -8); XCTAssertEqual(summary.totals.carryoverDebtRub, 76)
        var winter = FuelRecord(date: "2026-03-31", mileage: 100)
        XCTAssertEqual(FuelSummaryCalculator.build(records: [winter]).totals.fuelNorm, 10.058, accuracy: 0.00001)
        winter.date = "2026-04-01"
        XCTAssertEqual(FuelSummaryCalculator.build(records: [winter]).totals.fuelNorm, 9.4)
        let next = FuelRecord(date: "2026-07-31", mileage: 10)
        let july = try XCTUnwrap(FuelSummaryCalculator.build(records: records + [next]).monthly.last)
        XCTAssertEqual(july.incomingCarryoverDebtRub, 76); XCTAssertEqual(july.projectedPayout, 0)
    }
    func testMonthlyMileageUsesPOSAndARMAndReusesOneTaggedRow() throws {
        var pos = fixtureRoute(); pos.date = "2026-06-02"; pos.distanceKm = 7
        var arm = pos; arm.workType = .arm; arm.distanceKm = 10
        let mileage = try XCTUnwrap(RouteMonthlyMileage.build(month: "2026-06", days: [pos, arm]))
        XCTAssertEqual(mileage.totalKm, 17); XCTAssertEqual(mileage.latestDate, "2026-06-02")
        let record = mileage.record(replacing: FuelRecord(id: "month-id", date: "2026-06-01", mileage: 1))
        XCTAssertEqual(record.comment, "route_monthly_mileage|2026-06-02|17"); XCTAssertEqual(record.id, "month-id")
        XCTAssertNil(record.liters); XCTAssertNil(record.fuelCost)
        let index = FuelWire.monthlyMileageIndex(records: [FuelRecord(id: "refuel", date: "2026-06-03", mileage: 1, liters: 10), record], month: "2026-06")
        XCTAssertEqual(index, 1)
    }
    func testGsmProfileMappingPhoneNullIDsAndRequiredFields() throws {
        var value = try fixtureGsmProfile()
        XCTAssertEqual(value.employeePhone, "+7(000)000-00-00"); XCTAssertEqual(value.fuelNorm, 9.4)
        let payload = try GsmWire.profilePayload(value)
        XCTAssertTrue(payload["armProjectId"] is NSNull); XCTAssertEqual(payload["vehicleId"] as? String, "vehicle-fixture")
        XCTAssertEqual(payload["fuelTypes"] as? [String], ["АИ-95", "ДТ"])
        value.employeePhone = "123"; XCTAssertThrowsError(try GsmWire.profilePayload(value))
        value.employeePhone = "80000000000"; value.fuelNorm = 0; XCTAssertThrowsError(try GsmWire.profilePayload(value))
        let missing = try GsmWire.profile(["profile": NSNull(), "availableFuelTypes": ["ДТ"]])
        XCTAssertEqual(missing.profile, .empty); XCTAssertEqual(missing.availableFuelTypes, ["ДТ"])
        XCTAssertThrowsError(try GsmWire.profile(["unexpected": true]))
    }
    func testNewProfileComposesContactsFromCurrentEditorFields() throws {
        var value = try fixtureGsmProfile()
        value.employeeTitleCompany = ""; value.employeeAddressPhone = ""
        value.employeeJobTitle = "Новая должность"
        let payload = try GsmWire.profilePayload(value)
        XCTAssertEqual(payload["employeeTitleCompany"] as? String, "Тестовый сотрудник, Новая должность, Тестовая компания")
        XCTAssertEqual(payload["employeeAddressPhone"] as? String, "Тестовый город, Тестовая, 1, +7(000)000-00-00")
        XCTAssertEqual(payload["vehicleId"] as? String, "vehicle-fixture")
    }
    func testAuthenticatedPathsAndWritePayloadNeverInventConfirmation() async throws {
        let fixture = try gsmFuelFixture()
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let path = request.url!.path
            switch (request.httpMethod!, path) {
            case ("GET", "/api/v2/fuel"), ("GET", "/api/v2/gsm/profile"), ("GET", "/api/v2/gsm/projects"):
                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: fixture))
            case ("POST", "/api/v2/fuel"):
                let body = try JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as! [String: Any]
                XCTAssertEqual(body["mileage"] as? Int, 17); XCTAssertNil(body["liters"])
                return .init(status: 200, data: Data(#"{"id":"saved-id","recordType":"FUEL","date":"2026-06-02","mileage":17}"#.utf8))
            case ("POST", "/api/v2/gsm/report"):
                let body = try JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as! [String: String]
                XCTAssertEqual(body, ["month": "2026-06"]); XCTAssertEqual(request.timeoutInterval, 60)
                return .init(status: 200, data: Data(#"{"success":true,"month":"2026-06","generated":true,"sent":false,"status":"GENERATED"}"#.utf8))
            case ("GET", "/api/v2/gsm/odometer-suggestion"):
                XCTAssertEqual(request.url!.query, "month=2026-06")
                return .init(status: 200, data: Data(#"{"month":"2026-06","sourceMonth":"2026-05","startOdometer":100}"#.utf8))
            default: XCTFail("Unexpected request"); return .init(status: 500, data: Data())
            }
        }
        let service = GsmFuelService(config: AppConfig(lumaWorkAPIOrigin: "https://example.invalid"), authToken: "fixture-token", session: session)
        let fuel = try await service.fetchFuel(); XCTAssertEqual(fuel.count, 3)
        let profile = try await service.fetchProfile(); XCTAssertEqual(profile.profile.vehicleID, "vehicle-fixture")
        let projects = try await service.fetchProjects(); XCTAssertEqual(projects.count, 1)
        let saved = try await service.saveFuel(FuelRecord(date: "2026-06-02", mileage: 17))
        XCTAssertEqual(saved.id, "saved-id")
        let report = try await service.sendReport(month: "2026-06")
        XCTAssertFalse(report.confirmsEmailDelivery)
        let odometer = try await service.fetchStartOdometer(month: "2026-06"); XCTAssertEqual(odometer, 100)
    }
    func testUnauthorizedMalformedEmptyWriteAndWrongReportMonthAreErrors() async throws {
        for (status, json) in [(401, "{}"), (200, "{}"), (204, "")] {
            let session = FixtureURLProtocol.install { _ in .init(status: status, data: Data(json.utf8)) }
            let service = GsmFuelService(config: AppConfig(lumaWorkAPIOrigin: "https://example.invalid"), authToken: "fixture-token", session: session)
            do { _ = try await service.saveFuel(FuelRecord(date: "2026-06-02", mileage: 17)); XCTFail("Unconfirmed write accepted") } catch { }
        }
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: Data(#"{"success":true,"month":"2026-05","sent":true}"#.utf8)) }
        let service = GsmFuelService(config: AppConfig(lumaWorkAPIOrigin: "https://example.invalid"), authToken: "fixture-token", session: session)
        do { _ = try await service.sendReport(month: "2026-06"); XCTFail("Wrong month accepted") } catch { }
        for month in ["2026-13", "2026-00", "2026-6", ""] { XCTAssertFalse(GsmWire.isValidMonth(month)) }
    }
    func testHistoricalArchiveIsOwnerGatedAndCurrentBoundaryPreserved() {
        XCTAssertTrue(FuelArchivePolicy.isCurrent(FuelRecord(date: "2026-05-13")))
        XCTAssertFalse(FuelArchivePolicy.isCurrent(FuelRecord(date: "2026-05-12")))
        XCTAssertFalse(FuelArchivePolicy.isAvailable(userEmail: "test@example.invalid", ownerEmail: nil))
        XCTAssertTrue(FuelArchivePolicy.isAvailable(userEmail: " Test@example.invalid ", ownerEmail: "test@example.invalid"))
    }
}
