import XCTest
@testable import EngineerCore

final class AdminFeedbackContractTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "admin-feedback", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testFeedbackWireAndStableDraftIdentity() throws {
        let message = try FeedbackWire.decode(FeedbackMessage.self, json: fixture()["message"])
        XCTAssertEqual(message.status, .new)
        XCTAssertEqual(message.kind.rawValue, "ERROR")
        XCTAssertEqual(message.areaTitles, "Заявки")
        var draft = FeedbackDraft()
        draft.areas = [.requests]; draft.title = "Ошибка списка"; draft.message = "Описание ошибки в списке заявок."
        let restored = try JSONDecoder().decode(FeedbackDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.clientRequestID, draft.clientRequestID)
        XCTAssertNil(restored.validationMessage)
        draft.title = String(repeating: "x", count: 161)
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertNotEqual(message.resendDraft.clientRequestID, restored.clientRequestID)
    }
    func testFeedbackCreateRetryUsesSameIDAndRealMetadataKeys() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["message": fixture()["message"]!])
        var ids: [String] = []
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/v2/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as? [String: Any])
            ids.append(try XCTUnwrap(body["clientRequestId"] as? String))
            XCTAssertEqual((body["deviceInfo"] as? [String: Any])?["osVersion"] as? String, "macOS 15.6.1")
            XCTAssertTrue(body["otherArea"] is NSNull)
            return .init(status: 200, data: response)
        }
        defer { session.invalidateAndCancel() }
        let api = FeedbackAPI(config: AppConfig(lumaWorkAPIOrigin: "https://api.example.invalid"), token: "fixture-token", httpClient: HTTPClient(session: session))
        var draft = FeedbackDraft(); draft.areas = [.requests]; draft.title = "Ошибка списка"; draft.message = "Описание ошибки в списке заявок."
        let device = FeedbackDeviceInfo(deviceModel: "MacBookAir10,1", osVersion: "macOS 15.6.1", appVersion: "0.1.0 (1)", language: "ru", timeZone: "Europe/Simferopol", capturedAt: "2026-10-09T10:00:00Z")
        _ = try await api.createDraft(draft, device: device)
        _ = try await api.createDraft(draft, device: device)
        XCTAssertEqual(ids, [draft.clientRequestID.uuidString, draft.clientRequestID.uuidString])
    }
    func testAdminPermissionAndUserWire() throws {
        let root = try fixture()
        let user = try XCTUnwrap(root["users"] as? [[String: Any]]).map(AdminUserRecord.init(raw:))[0]
        XCTAssertEqual(user.permissionSet, [.viewUsers])
        XCTAssertEqual(user.appVersionDisplay, "0.1.0 (1)")
        XCTAssertFalse(AppUser(id: "u", email: "u@example.invalid", role: "user", adminPermissions: ["users.delete"]).can(.deleteUsers))
        XCTAssertFalse(AppUser(id: "u", email: "u@example.invalid", role: "admin", adminPermissions: []).canAccessAdminPanel)
        XCTAssertEqual(AdminPermission.allCases.count, 21)
    }
}
