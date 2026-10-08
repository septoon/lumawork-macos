import XCTest
@testable import EngineerCore

@MainActor private final class MapServiceFixture: RouteMapServing {
    var calls = 0
    var hold = false
    var suspended: CheckedContinuation<RouteMapSnapshot, Error>?
    func route(for plan: RouteMapPlan, force: Bool) async throws -> RouteMapSnapshot {
        calls += 1
        if hold { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return try mapSnapshotFixture()
    }
}
func mapSnapshotFixture() throws -> RouteMapSnapshot {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "map-route", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(RouteMapSnapshot.self, from: Data(contentsOf: url))
}
@MainActor final class RouteMapRepositoryTests: XCTestCase {
    var session = AppSession(token: "fixture-token", user: AppUser(id: "map-A", email: "map@example.invalid", role: "engineer"))
    var context: SessionContext? = SessionContext(epoch: 1, userID: "map-A", simpleOneUserID: nil)
    private func repository(_ storage: ScopedSnapshotStorage, service: MapServiceFixture) -> RouteDayRepository {
        RouteDayRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in RouteDayService(config: AppConfig(lumaWorkAPIOrigin: "https://example.invalid"), authToken: "fixture-token") }, mapService: { service })
    }
    func testMapSnapshotSurvivesRelaunchWithoutSecondCalculationAndVersionDrift() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 8, count: 32) })
        let service = MapServiceFixture()
        let first = repository(storage, service: service)
        _ = try await first.calculateMap(for: mapPlan())
        let reopened = repository(storage, service: service)
        let cached = try await reopened.prepareMap(for: mapPlan())
        XCTAssertEqual(cached?.distanceKm, 3)
        _ = try await reopened.calculateMap(for: mapPlan())
        XCTAssertEqual(service.calls, 1)
        XCTAssertNil(reopened.cachedMap(for: RouteMapPlan(addresses: ["Другой", "Точка", "Другой"])))
    }
    func testSingleFlightAndLateAccountResultCannotPublishOrPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 8, count: 32) })
        let service = MapServiceFixture(); service.hold = true
        let repo = repository(storage, service: service)
        let one = Task { try await repo.calculateMap(for: mapPlan()) }
        while service.suspended == nil { await Task.yield() }
        let two = Task { try await repo.calculateMap(for: mapPlan()) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.calls, 1)
        context = SessionContext(epoch: 2, userID: "map-B", simpleOneUserID: nil); session.user.id = "map-B"
        repo.synchronizeSession()
        service.suspended?.resume(returning: try mapSnapshotFixture()); service.suspended = nil
        do { _ = try await one.value; XCTFail("Late map accepted") } catch { }
        do { _ = try await two.value; XCTFail("Joined late map accepted") } catch { }
        XCTAssertNil(repo.cachedMap(for: mapPlan()))
        let data = try await storage.load(key: "routes.v1", scope: SnapshotScope(userID: "map-A"))
        XCTAssertNil(data)
    }
    func testConfirmedAddressCoordinatesAreScopedDurableAndForgettable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 8, count: 32) })
        let service = MapServiceFixture()
        let repo = repository(storage, service: service)
        let point = AppleRouteCoordinate(latitude: 55, longitude: 37)
        let address = "Алушта, Тестовая, 1"
        try await repo.rememberMapCoordinate(point, for: address)
        var record = fixtureRoute(); record.stops[1].address = address
        XCTAssertEqual(repo.mapPlan(for: record).coordinateOverrides[1], point)
        let reopened = repository(storage, service: service)
        _ = try await reopened.prepareMap(for: mapPlan())
        XCTAssertEqual(reopened.mapPlan(for: record).coordinateOverrides[1], point)
        try await reopened.rememberMapCoordinate(nil, for: address)
        XCTAssertNil(reopened.mapPlan(for: record).coordinateOverrides[1])
        context = SessionContext(epoch: 2, userID: "map-B", simpleOneUserID: nil); session.user.id = "map-B"
        repo.synchronizeSession()
        XCTAssertNil(repo.mapPlan(for: record).coordinateOverrides[1])
    }
    func testOldRouteVaultWithoutMapFieldsStillLoadsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 8, count: 32) })
        let record = fixtureRoute()
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        let data = try JSONSerialization.data(withJSONObject: ["remote": [record.key.storageKey: raw], "drafts": [:]])
        try await storage.save(data, key: "routes.v1", scope: SnapshotScope(userID: "map-A"))
        let repo = repository(storage, service: MapServiceFixture())
        let loaded = try await repo.prepare(record.key)
        XCTAssertEqual(loaded?.remote, record)
        XCTAssertNil(repo.cachedMap(for: mapPlan()))
    }
}
