import XCTest
@testable import EngineerCore

final class AuthContractTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "auth-session", withExtension: "json", subdirectory: "Fixtures")))
    }
    private func api(_ session: URLSession) -> LumaWorkAuthAPI {
        LumaWorkAuthAPI(config: AppConfig(lumaWorkAPIOrigin: "https://api.example.invalid"), session: session)
    }

    func testEmailCodeAndVerificationRequests() async throws {
        let fixture = try fixture()
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LumaWork-Version"), AppBuildIdentity.version)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as? [String: String])
            switch request.url!.path {
            case "/auth/request-code":
                XCTAssertEqual(json, ["email": "engineer@example.invalid"])
                return .init(status: 204, data: Data())
            case "/auth/verify-code":
                XCTAssertEqual(json, ["email": "engineer@example.invalid", "code": "000000"])
                return .init(status: 200, data: fixture)
            default:
                XCTFail("Unexpected auth path")
                return .init(status: 404, data: Data())
            }
        }
        defer { session.invalidateAndCancel() }
        try await api(session).requestCode(email: "engineer@example.invalid")
        let result = try await api(session).verifyCode(email: "engineer@example.invalid", code: "000000")
        XCTAssertEqual(result.user.id, "fixture-user-A")
        XCTAssertEqual(result.user.profile?.personnelNumber, "0000123")
        XCTAssertFalse(result.user.canAccessAdminPanel)
    }

    func testMeAndLogoutRequestShapes() async throws {
        let user = try JSONDecoder().decode(AppSession.self, from: fixture()).user
        let data = try JSONSerialization.data(withJSONObject: ["user": JSONSerialization.jsonObject(with: JSONEncoder().encode(user))])
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
            if request.url!.path == "/me" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.timeoutInterval, 8)
                return .init(status: 200, data: data)
            }
            XCTAssertEqual(request.url!.path, "/auth/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            return .init(status: 204, data: Data())
        }
        defer { session.invalidateAndCancel() }
        let currentUser = try await api(session).currentUser(token: "fixture-token")
        XCTAssertEqual(currentUser, user)
        try await api(session).logout(token: "fixture-token")
    }

    func testProfileRequestKeepsEveryFieldAndStringIdentifiers() async throws {
        let user = try JSONDecoder().decode(AppSession.self, from: fixture()).user
        let data = try JSONSerialization.data(withJSONObject: ["user": JSONSerialization.jsonObject(with: JSONEncoder().encode(user))])
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url!.path, "/api/v2/profile")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as? [String: String])
            XCTAssertEqual(body.count, 21)
            XCTAssertEqual(body["firstName"], "Иван")
            XCTAssertEqual(body["personnelNumber"], "0000123")
            XCTAssertEqual(body["workEmail"], "")
            return .init(status: 200, data: data)
        }
        defer { session.invalidateAndCancel() }
        _ = try await api(session).saveProfile(token: "fixture-token", profile: UserProfileData(firstName: " Иван ", personnelNumber: "0000123"))
    }

    func testErrorPayloadsKeepDomainMessagesAndHTTPStatuses() async throws {
        for (status, payload, message) in [
            (429, #"{"error":"CODE_RECENTLY_SENT","message":"Повторите через минуту."}"#, "Повторите через минуту."),
            (400, #"{"error":"INVALID_CODE"}"#, "Код не подошел или истек."),
            (403, #"{"error":"USER_BLOCKED"}"#, "Доступ был отозван. Для восстановления обратитесь в поддержку.")
        ] {
            let session = FixtureURLProtocol.install { _ in .init(status: status, data: Data(payload.utf8)) }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await api(session).verifyCode(email: "engineer@example.invalid", code: "000000")
                XCTFail("Auth failure accepted")
            } catch { XCTAssertEqual(error.localizedDescription, message) }
        }
        let session = FixtureURLProtocol.install { _ in .init(status: 401, data: Data("{}".utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await api(session).currentUser(token: "expired-fixture")
            XCTFail("401 accepted")
        } catch AppServiceError.http(let status, _) { XCTAssertEqual(status, 401) }
    }

    func testAdminPermissionsDoNotElevateAnEngineer() throws {
        var user = try JSONDecoder().decode(AppSession.self, from: fixture()).user
        user.adminPermissions = ["users.delete"]
        XCTAssertFalse(user.can(.deleteUsers))
        user.role = "admin"
        XCTAssertEqual(user.adminPermissionSet, [.deleteUsers])
        user.adminPermissions = []
        XCTAssertFalse(user.canAccessAdminPanel)
        user.adminPermissions = nil
        XCTAssertEqual(user.adminPermissionSet, Set(AdminPermission.allCases))
    }

    func testProfileEmptyValuesAndNamesMatchBaseline() {
        let profile = UserProfileData(firstName: " Иван ", lastName: " Тестов ", routeHomeAddress: " ")
        XCTAssertEqual(profile.fullName, "Тестов Иван")
        XCTAssertEqual(profile.shortDisplayName, "Иван")
        XCTAssertEqual(profile.requestBody["routeHomeAddress"], "")
        XCTAssertNil(UserProfileData.empty.fullName)
    }

    func testMalformedUserResponseFails() async throws {
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: Data("{}".utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await api(session).currentUser(token: "fixture-token")
            XCTFail("Malformed user accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "Сервер авторизации вернул некорректный ответ.") }
    }
}
