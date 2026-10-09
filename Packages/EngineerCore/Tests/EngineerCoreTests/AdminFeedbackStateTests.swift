import XCTest
@testable import EngineerCore

@MainActor final class AdminFeedbackStateTests: XCTestCase {
    private let config = AppConfig(lumaWorkAPIOrigin: "https://api.example.invalid")
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "admin-feedback", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testProtectedGrantCannotCrossDomainsOrSurviveLock() throws {
        let context = SessionContext(epoch: 1, userID: "fixture-user", simpleOneUserID: nil)
        var generation: UInt64 = 1
        let salary = SalaryAccess(context: { context }, generation: { generation })
        let admin = ProtectedAccess(context: { context }, generation: { generation })
        let salaryGrant = try salary.authorize(expectedContext: context, expectedGeneration: 1)
        let adminGrant = try admin.authorize(expectedContext: context, expectedGeneration: 1)
        XCTAssertFalse(admin.accepts(salaryGrant)); XCTAssertFalse(salary.accepts(adminGrant))
        generation = 2
        XCTAssertFalse(salary.accepts(salaryGrant)); XCTAssertFalse(admin.accepts(adminGrant))
        XCTAssertThrowsError(try admin.authorize(expectedContext: context, expectedGeneration: 1))
    }
    func testForbiddenClearsProtectedCacheAndChangesGate() async throws {
        let root = try fixture(), users = try JSONSerialization.data(withJSONObject: ["users": root["users"]!])
        var deny = false
        let transport = FixtureURLProtocol.install { _ in .init(status: deny ? 403 : 200, data: deny ? Data("{}".utf8) : users) }
        defer { transport.invalidateAndCancel() }
        let current = AppSession(token: "fixture-token", user: AppUser(id: "admin", email: "admin@example.invalid", role: "admin"))
        let context = SessionContext(epoch: 1, userID: "admin", simpleOneUserID: nil), client = HTTPClient(session: transport)
        let access = ProtectedAccess(context: { context }, generation: { 0 })
        let repository = AdminRepository(access: access, session: { current }, context: { context }, usersAPI: AdminUsersAPI(config: config, httpClient: client), overviewAPI: AdminOverviewAPI(config: config, httpClient: client), feedbackAPI: { FeedbackAPI(config: self.config, token: $0.token, httpClient: client) }, authFailure: { XCTFail("403 must not log out") }, report: { _ in })
        let grant = try access.authorize(expectedContext: context, expectedGeneration: 0)
        try await repository.load(.viewUsers, grant: grant); XCTAssertEqual(repository.users(grant: grant).count, 1)
        let generation = repository.accessGeneration; deny = true
        do { try await repository.load(.viewUsers, grant: grant, force: true); XCTFail("403 must fail") } catch {}
        XCTAssertTrue(repository.users(grant: grant).isEmpty); XCTAssertTrue(repository.forbidden)
        XCTAssertNotEqual(repository.accessGeneration, generation)
    }
    func testLateUserResponseCannotRestoreRevokedPermissions() async throws {
        let users = try JSONSerialization.data(withJSONObject: ["users": fixture()["users"]!])
        var current = AppSession(token: "fixture-token", user: AppUser(id: "admin", email: "admin@example.invalid", role: "admin"))
        let context = SessionContext(epoch: 1, userID: "admin", simpleOneUserID: nil)
        let transport = FixtureURLProtocol.install { _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { current.user.adminPermissions = [] } }
            return .init(status: 200, data: users)
        }
        defer { transport.invalidateAndCancel() }
        let client = HTTPClient(session: transport)
        let access = ProtectedAccess(context: { context }, generation: { 0 })
        let repository = AdminRepository(access: access, session: { current }, context: { context }, usersAPI: AdminUsersAPI(config: config, httpClient: client), overviewAPI: AdminOverviewAPI(config: config, httpClient: client), feedbackAPI: { FeedbackAPI(config: self.config, token: $0.token, httpClient: client) }, authFailure: {}, report: { _ in })
        let grant = try access.authorize(expectedContext: context, expectedGeneration: 0)
        do { try await repository.load(.viewUsers, grant: grant); XCTFail("Late result must be rejected") } catch is CancellationError {}
        repository.synchronizeSession(); XCTAssertTrue(repository.users(grant: grant).isEmpty)
    }
    func testLostFeedbackResponseReopenUsesOriginalIDAndSkipsReupload() async throws {
        let root = try fixture(), accepted = try JSONSerialization.data(withJSONObject: ["message": root["message"]!])
        var fail = true, ids: [String] = []
        let transport = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/v2/feedback") // Already NEW must never upload or submit again.
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureURLProtocol.bodyData(of: request)) as? [String: Any])
            ids.append(try XCTUnwrap(body["clientRequestId"] as? String))
            return .init(status: fail ? 500 : 200, data: fail ? Data("{}".utf8) : accepted)
        }
        defer { transport.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = ScopedSnapshotStorage(root: folder, keyProvider: { _ in Data(repeating: 7, count: 32) })
        let current = AppSession(token: "fixture-token", user: AppUser(id: "fixture-user", email: "fixture@example.invalid", role: "user"))
        let context = SessionContext(epoch: 1, userID: current.user.id, simpleOneUserID: nil)
        func repository() -> FeedbackRepository {
            FeedbackRepository(session: { current }, context: { context }, storage: { storage }, service: { FeedbackAPI(config: self.config, token: $0.token, httpClient: HTTPClient(session: transport)) }, authFailure: {}, report: { _ in })
        }
        let slot = UUID(), device = FeedbackDeviceInfo(deviceModel: "MacBookAir10,1", osVersion: "macOS 15.6.1", appVersion: "0.1.0 (1)", language: "ru", timeZone: "UTC", capturedAt: "2026-10-09T10:00:00Z")
        let pending = FeedbackPending(draft: FeedbackDraft(title: "Ошибка списка", message: "Описание ошибки в списке заявок.", areas: [.requests]), images: [FeedbackSelectedImage(data: Data([1]), fileName: "fixture.jpg")])
        let first = repository()
        do { _ = try await first.submit(pending, slot: slot, device: device, expectedContext: context); XCTFail("500 must fail") } catch {}
        let reopened = repository()
        let restoredValue = try await reopened.pending(slot: slot)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertTrue(restored.attempted); XCTAssertEqual(restored.images, pending.images)
        fail = false
        _ = try await reopened.submit(restored, slot: slot, device: device, expectedContext: context)
        XCTAssertEqual(ids, [pending.draft.clientRequestID.uuidString, pending.draft.clientRequestID.uuidString])
        XCTAssertEqual(reopened.messages.count, 1)
        let cleared = try await reopened.pending(slot: slot); XCTAssertFalse(cleared?.hasContent ?? false)
    }
}
