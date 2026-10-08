import XCTest
@testable import EngineerCore

final class RouteMapLinkTests: XCTestCase {
    func testWebRoutePreservesOrderEndpointAndAvoidanceContract() throws {
        let url = try XCTUnwrap(RouteMapLinks.webURL(baseURL: "https://yandex.ru/maps/?old=value", addresses: [" Тестовая,1 ", "Симферополь, улица Примерная, 2", "Тестовая,1"]))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "yandex.ru")
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(parts.queryItems).map { ($0.name, $0.value) })
        XCTAssertEqual(query["rtext"], "Алушта, Тестовая, 1~Симферополь, улица Примерная, 2~Алушта, Тестовая, 1")
        XCTAssertEqual(query["rtt"], "auto")
        XCTAssertEqual(query["routes[avoid]"], "unpaved,poor_condition")
        XCTAssertNil(query["old"])
    }
    func testManualCoordinatesTakePriorityAndBlankStopsDoNotShiftOverrides() throws {
        let url = try XCTUnwrap(RouteMapLinks.webURL(baseURL: "https://yandex.ru/maps/", addresses: ["Начало", " ", "Конец"], coordinateOverrides: [AppleRouteCoordinate(latitude: 55, longitude: 37), AppleRouteCoordinate(latitude: 56, longitude: 38), AppleRouteCoordinate(latitude: 999, longitude: 39)]))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "rtext" }?.value, "55.0,37.0~Алушта, Конец")
    }
    func testIncompleteRouteAndInvalidBaseCannotOpenLink() {
        XCTAssertNil(RouteMapLinks.webURL(baseURL: nil, addresses: ["А", "Б"]))
        XCTAssertNil(RouteMapLinks.webURL(baseURL: "https://yandex.ru/maps/", addresses: [" ", "Б"]))
        XCTAssertNil(RouteMapLinks.webURL(baseURL: "file:///tmp/private", addresses: ["А", "Б"]))
        XCTAssertNil(RouteMapLinks.webURL(baseURL: "javascript:alert(1)", addresses: ["А", "Б"]))
    }
}
