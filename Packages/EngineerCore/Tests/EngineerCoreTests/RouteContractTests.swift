import XCTest
@testable import EngineerCore

func fixtureRoute(_ type: RouteWorkType = .arm, date: String = "2026-10-08") -> RouteDayRecord {
    RouteDayRecord(date: date, workType: type, stops: [
        RouteStop(id: "local-start", address: " Синтетический склад ", reason: "Подготовка оборудования", status: .done),
        RouteStop(id: "local-middle", address: " Тестовая улица, 1 ", org: " Тест ", tid: " 00123 ", reason: " Обслуживание ", status: .declined, declineReason: " Нет доступа ", requestNumber: " REQ0001 ", coordinateOverride: AppleRouteCoordinate(latitude: 55.75, longitude: 37.61)),
        RouteStop(id: "local-finish", address: " Синтетический склад ", reason: "Сдача оборудования", status: .done)
    ], distanceKm: 23, periodStartOdometer: 12000, sent: false)
}
func routeFixture(_ name: String = "route-days") throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
}
func routeAPI(_ session: URLSession) -> RouteDayService {
    RouteDayService(config: AppConfig(lumaWorkAPIOrigin: "https://api.example.invalid"), authToken: "fixture-token", session: session)
}

final class RouteContractTests: XCTestCase {
    func testARMUpsertPreservesExactWireAndReconcilesServerIDs() async throws {
        let expected = try JSONSerialization.jsonObject(with: routeFixture("route-send-arm")) as! NSDictionary
        let response = try JSONSerialization.jsonObject(with: routeFixture()) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: (response["records"] as! [Any])[0])
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/v2/routes")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let actual = try JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as! NSDictionary
            XCTAssertEqual(actual, expected)
            return .init(status: 201, data: data)
        }
        defer { session.invalidateAndCancel() }
        let result = try await routeAPI(session).sendDay(fixtureRoute(), date: "2026-10-08", settings: .default)
        XCTAssertEqual(result.stops.map(\.id), ["server-0", "server-1", "server-2"])
        XCTAssertEqual(result.stops[1].declineReason, "Нет доступа")
    }

    func testPOSNullMileageAndCoordinateRemainJSONNull() async throws {
        let session = FixtureURLProtocol.install { request in
            let body = try JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as! [String: Any]
            XCTAssertEqual(body["workType"] as? String, "POS")
            XCTAssertTrue(body["distanceKm"] is NSNull)
            XCTAssertTrue(body["periodStartOdometer"] is NSNull)
            let stops = body["stops"] as! [[String: Any]]
            XCTAssertEqual(stops[1]["status"] as? String, "В процессе")
            XCTAssertTrue(stops[1]["coordinateOverride"] is NSNull)
            return .init(status: 201, data: try JSONSerialization.data(withJSONObject: body))
        }
        defer { session.invalidateAndCancel() }
        var record = fixtureRoute(.pos)
        record.distanceKm = nil; record.periodStartOdometer = nil
        record.stops[1].status = .pending; record.stops[1].coordinateOverride = nil
        _ = try await routeAPI(session).sendDay(record, date: record.date, settings: .default)
    }

    func testDayQueryAndArchiveAliasesKeepTypeAndOrder() async throws {
        let data = try routeFixture()
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) }), ["from": "2026-10-08", "to": "2026-10-08", "workType": "ARM"])
            return .init(status: 200, data: data)
        }
        defer { session.invalidateAndCancel() }
        let fetched = try await routeAPI(session).fetchDay(date: "2026-10-08", workType: .arm, settings: .default)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.workType, .arm)
        // iOS derives this display field from distanceKm, even when a reported field exists.
        XCTAssertEqual(record.reportedDistanceKm, 23)
        XCTAssertEqual(record.fuelLiters, 10.5)
        XCTAssertEqual(record.fuelCostRub, 600)
        XCTAssertEqual(record.requestNumbersSummary, "REQ0001")
        XCTAssertEqual(record.routeSummary, "Склад → Тестовая улица → Склад")
        XCTAssertEqual(record.stops.map(\.status), [.done, .declined, .done])
    }

    func testEmptyDayDoesNotInventRemoteRecordAndUnknownEnvelopeFails() async throws {
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: Data(#"{"days":{},"records":[]}"#.utf8)) }
        defer { session.invalidateAndCancel() }
        let record = try await routeAPI(session).fetchDay(date: "2026-10-08", workType: .pos, settings: .default)
        XCTAssertNil(record)
        let malformed = FixtureURLProtocol.install { _ in .init(status: 200, data: Data(#"{"unexpected":true}"#.utf8)) }
        defer { malformed.invalidateAndCancel() }
        do {
            _ = try await routeAPI(malformed).fetchAllDays(settings: .default)
            XCTFail("Unknown envelope accepted as empty archive")
        } catch RouteDayServiceError.invalidResponse { }
    }

    func testLostWriteResponseReadsBackOnceAndOnlyMatchingDaySucceeds() async throws {
        let data = try routeFixture()
        var requests: [String] = []
        let session = FixtureURLProtocol.install { request in
            requests.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return .init(status: 200, data: data)
        }
        defer { session.invalidateAndCancel() }
        let record = try await routeAPI(session).sendDay(fixtureRoute(), date: "2026-10-08", settings: .default)
        XCTAssertEqual(record.stops[1].id, "server-1")
        XCTAssertEqual(requests, ["POST", "GET"])
        let mismatch = FixtureURLProtocol.install { request in
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
            return .init(status: 200, data: Data(#"{"records":[]}"#.utf8))
        }
        defer { mismatch.invalidateAndCancel() }
        do {
            _ = try await routeAPI(mismatch).sendDay(fixtureRoute(), date: "2026-10-08", settings: .default)
            XCTFail("Missing readback falsely accepted")
        } catch let error as RouteDayServiceError { XCTAssertTrue(error.shouldQueue) }
    }

    func test401IsAuthenticationFailureNotQueueable() async throws {
        let session = FixtureURLProtocol.install { _ in .init(status: 401, data: Data()) }
        defer { session.invalidateAndCancel() }
        do { _ = try await routeAPI(session).fetchAllDays(settings: .default); XCTFail("401 accepted") }
        catch let error as RouteDayServiceError { XCTAssertFalse(error.shouldQueue); if case .unauthorized = error {} else { XCTFail("Lost auth state") } }
    }
    func testReadback401AfterLostPostResponseRemainsAuthenticationFailure() async throws {
        let session = FixtureURLProtocol.install { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return .init(status: 401, data: Data())
        }
        defer { session.invalidateAndCancel() }
        do { _ = try await routeAPI(session).sendDay(fixtureRoute(), date: "2026-10-08", settings: .default); XCTFail("401 accepted") }
        catch let error as RouteDayServiceError {
            XCTAssertFalse(error.shouldQueue)
            guard case .unauthorized = error else { return XCTFail("Readback lost auth state") }
        }
    }
}
