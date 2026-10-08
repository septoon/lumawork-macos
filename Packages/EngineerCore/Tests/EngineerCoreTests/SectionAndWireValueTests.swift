import XCTest
@testable import EngineerCore

final class SectionAndWireValueTests: XCTestCase {
    func testExactSectionMappingAndPermissions() {
        let expected = [
            ("home", "Главная"), ("backpack", "Мой рюкзак"), ("employees", "Сотрудники"),
            ("maintenance", "Авто"), ("fuel", "Топливо"), ("wiki", "Помощник"),
            ("ftp", "FTP"), ("salary", "Зарплата"), ("requests", "Заявки"),
            ("coordination", "Координация"), ("timeReport", "Трудозатраты"),
            ("analytics", "Аналитика"), ("users", "Админка")
        ]
        XCTAssertEqual(EngineerSection.allCases.map(\.rawValue), expected.map(\.0))
        XCTAssertEqual(EngineerSection.allCases.map(\.title), expected.map(\.1))
        XCTAssertEqual(EngineerSection.availableCases(isAdmin: false).count, 12)
        XCTAssertFalse(EngineerSection.availableCases(isAdmin: false).contains(.users))
        XCTAssertEqual(EngineerSection.availableCases(isAdmin: true), EngineerSection.allCases)
        XCTAssertNil(EngineerSection(rawValue: "assistant"))
    }

    func testWorkTypeWireValuesAndStorageKeys() throws {
        XCTAssertEqual(RouteWorkType.arm.title, "АРМ")
        XCTAssertEqual(try JSONEncoder().encode(RouteWorkType.arm), Data("\"ARM\"".utf8))
        XCTAssertEqual(RouteWorkType.pos.storageKey(for: "2026-10-08"), "2026-10-08")
        XCTAssertEqual(RouteWorkType.arm.storageKey(for: "2026-10-08"), "2026-10-08|ARM")
        XCTAssertEqual(try JSONDecoder().decode(RouteWorkType.self, from: Data("\"POS\"".utf8)), .pos)
        XCTAssertThrowsError(try JSONDecoder().decode(RouteWorkType.self, from: Data("\"АРМ\"".utf8)))
    }

    func testSalaryAndStopRawValues() throws {
        XCTAssertEqual(SalaryPaymentKind.allCases.map(\.rawValue), ["advance", "salary", "weekend", "gsm", "other"])
        XCTAssertEqual(SalaryPaymentKind.gsm.title, "Компенсация ГСМ")
        XCTAssertEqual(try JSONDecoder().decode(RouteStopStatus.self, from: Data("\"declined\"".utf8)), .declined)
        XCTAssertEqual(try JSONEncoder().encode(RouteStopStatus.done), Data("\"done\"".utf8))
    }
}
