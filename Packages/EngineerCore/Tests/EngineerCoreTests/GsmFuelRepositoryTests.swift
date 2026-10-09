import XCTest
@testable import EngineerCore

@MainActor final class GsmFuelFixtureService: GsmFuelServing {
    var records = try! fixtureFuelRecords()
    var profile = try! GsmWire.profile(gsmFuelFixture())
    var fuelCalls = 0
    var saves = 0
    var reports = 0
    var holdFuel = false
    var heldFuel: CheckedContinuation<[FuelRecord], Error>?
    var holdReport = false
    var heldReport: CheckedContinuation<GsmReportResponse, Error>?
    var failure: Error?
    func fetchFuel() async throws -> [FuelRecord] {
        fuelCalls += 1
        if let failure { throw failure }
        if holdFuel { return try await withCheckedThrowingContinuation { heldFuel = $0 } }
        return records
    }
    func saveFuel(_ record: FuelRecord) async throws -> FuelRecord {
        saves += 1; var result = record; result.id = result.id ?? "saved-new"
        records.removeAll { $0.id == result.id }; records.append(result); return result
    }
    func deleteFuel(id: String) async throws { records.removeAll { $0.id == id } }
    func fetchProfile() async throws -> GsmProfileLoadResult { profile }
    func fetchProjects() async throws -> [GsmProjectOption] { try GsmWire.projects(gsmFuelFixture()) }
    func saveProfile(_ profile: GsmProfile) async throws -> GsmProfileLoadResult { self.profile = .init(profile: profile, availableFuelTypes: ["АИ-95", "ДТ"]); return self.profile }
    func fetchStartOdometer(month: String) async throws -> Int? { 100 }
    func sendReport(month: String) async throws -> GsmReportResponse {
        reports += 1
        if holdReport { return try await withCheckedThrowingContinuation { heldReport = $0 } }
        return try JSONDecoder().decode(GsmReportResponse.self, from: Data(#"{"success":true,"month":"2026-06","sent":true}"#.utf8))
    }
}
@MainActor final class GsmFuelRepositoryTests: XCTestCase {
    var session = AppSession(token: "fixture-token", user: AppUser(id: "fuel-A", email: "fuel@example.invalid", role: "engineer"))
    var context: SessionContext? = SessionContext(epoch: 1, userID: "fuel-A", simpleOneUserID: nil)
    func make(_ storage: ScopedSnapshotStorage, _ service: GsmFuelFixtureService, auth: @escaping () -> Void = {}) -> GsmFuelRepository {
        GsmFuelRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in service }, authFailure: auth)
    }
    func storage(_ root: URL) -> ScopedSnapshotStorage { ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 9, count: 32) }) }
    func testEncryptedCacheRelaunchOfflineAndAccountIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(), disk = storage(root), repo = make(storage(root), GsmFuelFixtureService())
        try await repo.loadFuel(); try await repo.loadGsm()
        let reopened = make(disk, service); try await reopened.prepare()
        XCTAssertEqual(reopened.records.count, 3); XCTAssertEqual(reopened.profile?.profile.vehicleID, "vehicle-fixture")
        service.failure = GsmFuelError.infrastructure("Offline")
        do { try await reopened.loadFuel(force: true); XCTFail() } catch { }
        XCTAssertEqual(reopened.records.count, 3); XCTAssertEqual(reopened.fuelConnection, .offline)
        context = SessionContext(epoch: 2, userID: "fuel-B", simpleOneUserID: nil); session.user.id = "fuel-B"
        reopened.synchronizeSession(); XCTAssertTrue(reopened.records.isEmpty); XCTAssertNil(reopened.profile)
        try await reopened.prepare(); XCTAssertTrue(reopened.records.isEmpty)
    }
    func testSingleFlightLateAccountCannotPublishOrPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(); service.holdFuel = true
        let disk = storage(root); let repo = make(disk, service)
        let first = Task { try await repo.loadFuel() }
        while service.heldFuel == nil { await Task.yield() }
        let second = Task { try await repo.loadFuel() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.fuelCalls, 1)
        context = SessionContext(epoch: 2, userID: "fuel-B", simpleOneUserID: nil); session.user.id = "fuel-B"; repo.synchronizeSession()
        service.heldFuel?.resume(returning: service.records); service.heldFuel = nil
        do { try await first.value; XCTFail() } catch { }; do { try await second.value; XCTFail() } catch { }
        XCTAssertTrue(repo.records.isEmpty)
        let persisted = try await disk.load(key: "gsm-fuel.v1", scope: SnapshotScope(userID: "fuel-A")); XCTAssertNil(persisted)
    }
    func testFuelPreflightConflictAndLateReadNeverReplaceWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(), repo = make(storage(root), GsmFuelFixtureService())
        let live = make(storage(root), service); try await live.loadFuel()
        let base = service.records[0]; var draft = base; draft.mileage = 200
        service.records[0].mileage = 300
        do { _ = try await live.saveFuel(draft, base: base); XCTFail("Conflict overwritten") } catch { }
        XCTAssertEqual(service.saves, 0)
        service.records[0] = base; service.holdFuel = true
        let old = Task { try await live.loadFuel(force: true) }
        while service.heldFuel == nil { await Task.yield() }
        service.holdFuel = false
        _ = try await live.saveFuel(draft, base: base)
        service.heldFuel?.resume(returning: [base]); service.heldFuel = nil
        do { try await old.value; XCTFail("Old GET accepted") } catch { }
        XCTAssertEqual(live.records.first(where: { $0.id == base.id })?.mileage, 200)
        try await repo.prepare(); XCTAssertEqual(repo.records.first(where: { $0.id == base.id })?.mileage, 200)
    }
    func testProfileDraftCannotOverwriteAnotherWindowAndReportIsSingleSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(), repo = make(storage(root), GsmFuelFixtureService())
        let live = make(storage(root), service); try await live.loadGsm()
        let base = try XCTUnwrap(live.profile?.profile); var one = base; one.carModel = "One"
        _ = try await live.saveProfile(one, base: base)
        var two = base; two.carModel = "Two"
        do { _ = try await live.saveProfile(two, base: base); XCTFail("Old draft accepted") } catch { }
        XCTAssertEqual(live.profile?.profile.carModel, "One")
        service.holdReport = true
        let report = Task { try await live.sendReport(month: "2026-06") }
        while service.heldReport == nil { await Task.yield() }
        do { _ = try await live.sendReport(month: "2026-06"); XCTFail("Duplicate sent") } catch { }
        XCTAssertEqual(service.reports, 1)
        service.heldReport?.resume(returning: try JSONDecoder().decode(GsmReportResponse.self, from: Data(#"{"success":true,"month":"2026-06","sent":true}"#.utf8))); service.heldReport = nil
        _ = try await report.value; XCTAssertFalse(live.isMutating)
        try await repo.prepare(); XCTAssertEqual(repo.profile?.profile.carModel, "One")
    }
    func testMonthlyMileageRefreshesAndUpdatesTaggedRowWithoutDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService()
        service.records = [FuelRecord(id: "monthly", comment: "route_monthly_mileage|2026-06-01|7", date: "2026-06-01", mileage: 7)]
        let repo = make(storage(root), service)
        var day = fixtureRoute(); day.date = "2026-06-02"; day.distanceKm = 17
        let mileage = try XCTUnwrap(RouteMonthlyMileage.build(month: "2026-06", days: [day]))
        _ = try await repo.syncMonthlyMileage(mileage)
        XCTAssertEqual(repo.records.count, 1); XCTAssertEqual(repo.records[0].id, "monthly"); XCTAssertEqual(repo.records[0].mileage, 17)
        _ = try await repo.syncMonthlyMileage(mileage); XCTAssertEqual(service.saves, 1)
    }
    func testMonthlyMileageCannotCrossAccountAfterRefreshCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(); service.records = []
        var repo: GsmFuelRepository!
        var switched = false
        repo = GsmFuelRepository(session: { self.session }, context: {
            // Switch at the first context observation after the complete refresh unwinds.
            if service.fuelCalls > 0, repo?.isLoadingFuel == false, !switched {
                switched = true
                self.context = SessionContext(epoch: 2, userID: "fuel-B", simpleOneUserID: nil); self.session.user.id = "fuel-B"
            }
            return self.context
        }, storage: { self.storage(root) }, service: { _ in service })
        var day = fixtureRoute(); day.date = "2026-06-02"; day.distanceKm = 17
        let mileage = try XCTUnwrap(RouteMonthlyMileage.build(month: "2026-06", days: [day]))
        do { _ = try await repo.syncMonthlyMileage(mileage); XCTFail("A mileage was written after switching to B") } catch { }
        XCTAssertTrue(switched); XCTAssertEqual(service.saves, 0)
    }
    func testUnauthorizedHidesCacheAndInvokesAuthFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let service = GsmFuelFixtureService(); var invalidations = 0
        let repo = make(storage(root), service, auth: { invalidations += 1 }); try await repo.loadFuel()
        service.failure = GsmFuelError.unauthorized
        do { try await repo.loadFuel(force: true); XCTFail() } catch { }
        XCTAssertTrue(repo.records.isEmpty); XCTAssertTrue(repo.requiresAuthentication); XCTAssertEqual(invalidations, 1)
    }
}
