import XCTest
@testable import EngineerCore

@MainActor
final class MapTransportFixture: RouteMapTransport {
    var geocodeCount = 0
    var searchCount = 0
    var legCount = 0
    var suspect = false
    var duplicate = false
    var failLeg: Int?
    var holdLeg = false
    var suspended: CheckedContinuation<RouteMapLeg, Error>?
    func geocode(_ query: String) async throws -> [RouteMapCandidate] {
        geocodeCount += 1
        let index = query.contains("Вторая") ? 1 : 0
        return [RouteMapCandidate(coordinate: AppleRouteCoordinate(latitude: 55 + Double(duplicate ? 0 : index), longitude: 37), address: suspect ? "Другой город, улица Другая, 99" : query)]
    }
    func search(_ query: String, near: AppleRouteCoordinate?) async throws -> [RouteMapCandidate] { searchCount += 1; return [] }
    func leg(from: AppleRouteCoordinate, to: AppleRouteCoordinate) async throws -> RouteMapLeg {
        legCount += 1
        if failLeg == legCount { throw URLError(.cannotConnectToHost) }
        if holdLeg { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return RouteMapLeg(distanceMeters: legCount == 1 ? 1001 : 1000, coordinates: [from, to])
    }
}
func mapPlan() -> RouteMapPlan {
    RouteMapPlan(addresses: ["Алушта, Первая,1", "Алушта, Вторая,2", "Алушта, Первая,1"])
}

@MainActor
final class RouteMapTests: XCTestCase {
    func testPlanCacheKeyStableAcrossInstances() {
        XCTAssertEqual(Set((0..<40).map { _ in mapPlan().storageKey }).count, 1)
    }
    func testOrderedLegsKeepReturnEndpointAndRoundTotalUp() async throws {
        let transport = MapTransportFixture()
        let calculator = RouteMapCalculator(transport: transport)
        let result = try await calculator.route(for: mapPlan())
        XCTAssertEqual(result.distanceKm, 3)
        XCTAssertEqual(result.legs.count, 2)
        XCTAssertEqual(result.stopCoordinates.first, result.stopCoordinates.last)
        XCTAssertEqual(result.unverifiedStopIndices, [])
        XCTAssertTrue(result.canApplyDistance)
        _ = try await calculator.route(for: mapPlan())
        XCTAssertEqual(transport.geocodeCount, 2)
        XCTAssertEqual(transport.legCount, 2)
    }
    func testOverridesSkipGeocodingAndSeparateEqualAddressLocations() async throws {
        let transport = MapTransportFixture()
        let coordinates = [AppleRouteCoordinate(latitude: 55, longitude: 37), AppleRouteCoordinate(latitude: 56, longitude: 37), AppleRouteCoordinate(latitude: 57, longitude: 37)]
        let plan = RouteMapPlan(addresses: ["А", "А", "А"], coordinateOverrides: coordinates.map { Optional($0) })
        let result = try await RouteMapCalculator(transport: transport).route(for: plan)
        XCTAssertEqual(result.stopCoordinates, coordinates)
        XCTAssertEqual(transport.geocodeCount, 0)
        XCTAssertEqual(result.legs.count, 2)
    }
    func testIncompleteAndEmptyPlansDoNotRequestDirections() async throws {
        let transport = MapTransportFixture()
        let calculator = RouteMapCalculator(transport: transport)
        let empty = try await calculator.route(for: RouteMapPlan(addresses: ["Старт", " ", "Финиш"]))
        XCTAssertEqual(empty.distanceKm, 0)
        XCTAssertFalse(empty.canApplyDistance)
        do { _ = try await calculator.route(for: RouteMapPlan(addresses: [" ", "Точка", "Финиш"])); XCTFail("Incomplete route accepted") }
        catch RouteMapError.incompleteRoute { }
        XCTAssertEqual(transport.geocodeCount, 0)
    }
    func testSuspectAndDuplicateLocationsNeedConfirmation() async throws {
        let suspect = MapTransportFixture(); suspect.suspect = true
        let result = try await RouteMapCalculator(transport: suspect).route(for: mapPlan())
        XCTAssertEqual(result.unverifiedStopIndices, [0, 1, 2])
        XCTAssertFalse(result.canApplyDistance)
        XCTAssertEqual(suspect.searchCount, 2)
        let duplicate = MapTransportFixture(); duplicate.duplicate = true
        let repeated = try await RouteMapCalculator(transport: duplicate).route(for: mapPlan())
        XCTAssertEqual(repeated.unverifiedStopIndices, [0, 1, 2])
        XCTAssertFalse(repeated.canApplyDistance)
    }
    func testFailedLegKeepsPointsButNeverAppliesZeroMileage() async throws {
        let transport = MapTransportFixture(); transport.failLeg = 2
        let result = try await RouteMapCalculator(transport: transport).route(for: mapPlan())
        XCTAssertEqual(result.stopCoordinates.count, 3)
        XCTAssertTrue(result.routingIncomplete)
        XCTAssertEqual(result.failedLegIndex, 1)
        XCTAssertEqual(result.legs, [])
        XCTAssertFalse(result.canApplyDistance)
        XCTAssertNotNil(result.failureDescription)
    }
    func testCancelledCalculationDoesNotAcceptLateDirections() async throws {
        let transport = MapTransportFixture(); transport.holdLeg = true
        let task = Task { try await RouteMapCalculator(transport: transport).route(for: mapPlan()) }
        while transport.suspended == nil { await Task.yield() }
        task.cancel()
        transport.suspended?.resume(returning: RouteMapLeg(distanceMeters: 1, coordinates: [])); transport.suspended = nil
        do { _ = try await task.value; XCTFail("Cancelled calculation accepted") } catch is CancellationError { }
    }
    func testSnapshotVersionPlanIdentityAndDraftApplication() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "map-route", withExtension: "json", subdirectory: "Fixtures"))
        var snapshot = try JSONDecoder().decode(RouteMapSnapshot.self, from: Data(contentsOf: url))
        let plan = mapPlan()
        XCTAssertTrue(snapshot.matches(plan))
        var record = fixtureRoute(.pos)
        for i in record.stops.indices { record.stops[i].address = plan.addresses[i]; record.stops[i].coordinateOverride = nil }
        let draft = RouteDraftController(record: record)
        XCTAssertTrue(draft.applyMapDistance(snapshot, source: record, plan: plan))
        XCTAssertEqual(draft.record.distanceKm, 3)
        draft.updateStop(record.stops[1].id, address: "Другой адрес")
        XCTAssertFalse(draft.applyMapDistance(snapshot, source: record, plan: plan))
        snapshot.geocodingVersion = 2
        XCTAssertFalse(snapshot.matches(plan))
        var changed = plan.coordinateOverrides; changed[1] = AppleRouteCoordinate(latitude: 57, longitude: 39)
        XCTAssertFalse(snapshot.matches(RouteMapPlan(addresses: plan.addresses, coordinateOverrides: changed)))
    }
    func testStreetAndHouseValidationKeepsSuffixAndTownBoundaries() {
        XCTAssertTrue(RouteMapAddressValidation.matches(query: "Алушта, Тестовая, 9а", found: "город Алушта, улица Тестовая, дом 9-а"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, Тестовая, 9а", found: "Ялта, Тестовая, 9а"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, Тестовая, 9", found: "Алушта, Тестовая, 9а"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, Тестовая, 9", found: "Алушта, Тестовая"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, 9 Мая, 9", found: "Алушта, улица 9 Мая"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, 9 Мая, 9", found: "Алушта, улица 9 Мая, 20"))
        XCTAssertTrue(RouteMapAddressValidation.matches(query: "Алушта, 9 Мая, 9", found: "Алушта, улица 9 Мая, 9"))
        XCTAssertFalse(RouteMapAddressValidation.matches(query: "Алушта, улица Ленина, 1", found: "Алушта, переулок Ленина, 1"))
    }
    func testEquivalentRememberedPointConfirmationDoesNotBlockMileage() throws {
        let snapshot = try mapSnapshotFixture()
        var record = fixtureRoute(.pos)
        for i in record.stops.indices { record.stops[i].address = mapPlan().addresses[i]; record.stops[i].coordinateOverride = nil }
        var overrides = mapPlan().coordinateOverrides
        overrides[1] = snapshot.stopCoordinates[1]
        let plan = RouteMapPlan(addresses: mapPlan().addresses, coordinateOverrides: overrides)
        let calculated = RouteMapSnapshot(plan: plan, distanceKm: snapshot.distanceKm, stopCoordinates: snapshot.stopCoordinates, legs: snapshot.legs)
        let draft = RouteDraftController(record: record)
        draft.updateStop(record.stops[1].id, coordinate: .some(snapshot.stopCoordinates[1]))
        XCTAssertTrue(draft.applyMapDistance(calculated, source: record, plan: plan))
        draft.updateStop(record.stops[1].id, coordinate: .some(AppleRouteCoordinate(latitude: 50, longitude: 30)))
        XCTAssertFalse(draft.applyMapDistance(calculated, source: record, plan: plan))
    }
}
