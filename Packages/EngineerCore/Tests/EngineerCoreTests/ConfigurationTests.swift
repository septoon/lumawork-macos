import XCTest
@testable import EngineerCore

final class ConfigurationTests: XCTestCase {
    func testResolutionKeepsPerKeyPrecedence() {
        XCTAssertEqual(AppConfig.resolve(keys: ["URL", "ORIGIN"], environment: ["URL": " https://env.invalid "], bundleValues: ["URL": "https://bundle.invalid"], defaultValues: ["URL": "https://defaults.invalid"]), "https://env.invalid")
        XCTAssertEqual(AppConfig.resolve(keys: ["URL", "ORIGIN"], environment: ["ORIGIN": "https://alias-env.invalid"], bundleValues: ["URL": "https://bundle.invalid"], defaultValues: [:]), "https://bundle.invalid")
        XCTAssertEqual(AppConfig.resolve(keys: ["URL", "ORIGIN"], environment: [:], bundleValues: [:], defaultValues: ["URL": "https://defaults.invalid"]), "https://defaults.invalid")
    }

    func testPlaceholdersAndEmptyValuesFallThrough() {
        XCTAssertEqual(AppConfig.resolve(keys: ["URL", "ORIGIN"], environment: ["URL": "$(URL)"], bundleValues: ["URL": " \n "], defaultValues: ["ORIGIN": " https://fallback.invalid " ]), "https://fallback.invalid")
        XCTAssertNil(AppConfig.resolve(keys: ["URL"], environment: [:], bundleValues: [:], defaultValues: [:]))
    }

    func testInvalidOriginsAreExplicitAndLegacyFallbackIsPreserved() throws {
        for value in [nil, "", "$(URL)", "file:///", "ftp://host.invalid", "example.invalid", "https://"] {
            XCTAssertThrowsError(try AppConfig.validatedURL(value))
            XCTAssertTrue(AppConfig.configuredURL(value).isFileURL)
        }
        XCTAssertEqual(try AppConfig.validatedURL("https://api.example.invalid/base").path, "/base")
        XCTAssertEqual(try AppConfig.validatedURL("http://localhost:3130").port, 3130)
    }
}
