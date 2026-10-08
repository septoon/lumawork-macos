import XCTest
@testable import EngineerCore

final class NetworkPrivacyTests: XCTestCase {
    func testAuthIdentityAndCredentialsAreRedactedFromNestedLogBody() {
        let sanitized = NetworkDiagnostics.sanitizedForLogging([
            "email": "private-mail@example.invalid",
            "username": "private-login",
            "auth_key": "private-cookie-key",
            "nested": [["password": "private-password", "token": "private-token", "code": "123456"]],
            "language": "ru"
        ])
        let text = String(describing: sanitized)
        for secret in ["private-mail", "private-login", "private-cookie-key", "private-password", "private-token", "123456"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("ru"))
    }
}
