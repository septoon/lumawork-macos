import XCTest
@testable import EngineerCore

@MainActor
final class SimpleOneAuthContractTests: XCTestCase {
    func testLoginAndMeKeepSimpleOneContract() async throws {
        let fixture = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "simpleone-auth", withExtension: "json", subdirectory: "Fixtures")))
        let session = FixtureURLProtocol.install { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.timeoutInterval, 25)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
            if request.url?.path == "/api/auth/login" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as? [String: String]
                XCTAssertEqual(body, ["username": "fixture.engineer", "password": "synthetic-password", "language": "ru"])
                return .init(status: 200, data: Data(#"{"status":"OK","data":{"auth_key":"synthetic-cookie"}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/api/user/me")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=synthetic-cookie")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
            return .init(status: 200, data: fixture)
        }
        defer { session.invalidateAndCancel() }
        let api = SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid/api"), session: session)
        let key = try await api.login(username: "fixture.engineer", password: "synthetic-password")
        let user = try await api.currentUser(authKey: key)
        XCTAssertEqual(user.sysID, "0000123")
        XCTAssertEqual(user.displayName, "Иван Тестов")
    }

    func testUnauthorizedAndServerErrorsRemainSeparate() async throws {
        for (status, payload, unauthorized) in [
            (401, "{}", true),
            (200, #"{"errors":[{"message":"Invalid credentials"}]}"#, true),
            (403, "{}", false),
            (200, #"{"message":"Service unavailable"}"#, false)
        ] {
            let session = FixtureURLProtocol.install { _ in .init(status: status, data: Data(payload.utf8)) }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid"), session: session).currentUser(authKey: "synthetic-cookie")
                XCTFail("Invalid response accepted")
            } catch let error as SimpleOneServiceError {
                if case .unauthorized = error { XCTAssertTrue(unauthorized) }
                else { XCTAssertFalse(unauthorized) }
            }
        }
    }

    func testLoginHTTP500CredentialEnvelopeShowsCredentialFailure() async throws {
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/login")
            return .init(status: 500, data: Data(#"{"status":"ERROR","errors":[{"message":"Wrong username or password"}]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let api = SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid/v1"), session: session)
        do {
            _ = try await api.login(username: "synthetic-login", password: "synthetic-password")
            XCTFail("Failed login accepted")
        } catch let error as SimpleOneServiceError {
            guard case .invalidCredentials = error else { return XCTFail("Server credential refusal hidden: \(error)") }
        }
    }

    func testUnknownHTTP500EnvelopeKeepsHTTPStatusAndServerExplanation() async throws {
        let session = FixtureURLProtocol.install { _ in
            .init(status: 500, data: Data(#"{"status":"ERROR","errors":[{"message":"Synthetic backend failure"}]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let api = SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid/v1"), session: session)
        do {
            _ = try await api.login(username: "synthetic-login", password: "synthetic-password")
            XCTFail("Failed login accepted")
        } catch let error as SimpleOneServiceError {
            guard case .server(let message) = error else { return XCTFail("Unrelated error treated as credentials") }
            XCTAssertTrue(message.contains("HTTP 500"))
            XCTAssertTrue(message.contains("Synthetic backend failure"))
        }
    }

    func testMissingIdentityAndEmptyAuthKeyFail() async throws {
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: Data(#"{"status":"OK","data":{"auth_key":""}}"#.utf8)) }
        defer { session.invalidateAndCancel() }
        let api = SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid"), session: session)
        do { _ = try await api.login(username: "a", password: "b"); XCTFail("Empty key accepted") } catch {}
        do { _ = try await api.currentUser(authKey: "c"); XCTFail("Missing identity accepted") } catch {}
    }
}
