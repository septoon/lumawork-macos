import XCTest
@testable import EngineerCore

private final class FeedbackAsyncProtocol: URLProtocol {
    static var handler: (@MainActor (URLRequest) async throws -> FixtureURLProtocol.Reply)?
    private var flight: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        flight = Task { @MainActor in
            do {
                let reply = try await Self.handler!(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { flight?.cancel() }
}
@MainActor final class FeedbackRecoveryTests: XCTestCase {
    private let config = AppConfig(lumaWorkAPIOrigin: "https://api.example.invalid")
    func testClosedWindowOutboxIsDiscoverableWithoutItsSceneSlot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScopedSnapshotStorage(root: folder, keyProvider: { _ in Data(repeating: 7, count: 32) })
        let current = AppSession(token: "fixture-token", user: AppUser(id: "fixture-user", email: "fixture@example.invalid", role: "user"))
        let context = SessionContext(epoch: 1, userID: current.user.id, simpleOneUserID: nil)
        func repository() -> FeedbackRepository { FeedbackRepository(session: { current }, context: { context }, storage: { store }, service: { FeedbackAPI(config: self.config, token: $0.token) }, authFailure: {}, report: { _ in }) }
        let old = repository(), oldSlot = UUID()
        let payload = FeedbackPending(draft: FeedbackDraft(title: "Ошибка списка", message: "Описание ошибки в списке заявок.", areas: [.requests]), images: [FeedbackSelectedImage(data: Data([1]), fileName: "fixture.jpg")], attempted: true)
        try await old.save(payload, slot: oldSlot, expectedContext: context)
        let fresh = repository()
        try await fresh.loadDraftIndex()
        let reference = try XCTUnwrap(fresh.availableDrafts.first)
        XCTAssertEqual(reference.id, oldSlot)
        let restored = try await fresh.pending(slot: reference.id)
        XCTAssertEqual(restored, payload)
        try fresh.claim(reference.id)
        XCTAssertTrue(fresh.availableDrafts.isEmpty)
        XCTAssertThrowsError(try fresh.claim(reference.id))
        fresh.release(reference.id)
        XCTAssertEqual(fresh.availableDrafts.count, 1)
    }
    func testOldRefreshCannotEraseJustSubmittedReport() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "admin-feedback", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let submitted = try JSONSerialization.data(withJSONObject: ["message": root["message"]!])
        let urlConfig = URLSessionConfiguration.ephemeral; urlConfig.protocolClasses = [FeedbackAsyncProtocol.self]
        let transport = URLSession(configuration: urlConfig)
        defer { transport.invalidateAndCancel(); FeedbackAsyncProtocol.handler = nil }
        var held: CheckedContinuation<Void, Never>?
        var hold = false
        FeedbackAsyncProtocol.handler = { request in
            if request.httpMethod == "POST" { return .init(status: 200, data: submitted) }
            if hold { await withCheckedContinuation { held = $0 } }
            return .init(status: 200, data: Data("{\"messages\":[]}".utf8))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScopedSnapshotStorage(root: folder, keyProvider: { _ in Data(repeating: 7, count: 32) })
        let current = AppSession(token: "fixture-token", user: AppUser(id: "fixture-user", email: "fixture@example.invalid", role: "user"))
        let context = SessionContext(epoch: 1, userID: current.user.id, simpleOneUserID: nil)
        let repo = FeedbackRepository(session: { current }, context: { context }, storage: { store }, service: { FeedbackAPI(config: self.config, token: $0.token, httpClient: HTTPClient(session: transport)) }, authFailure: {}, report: { _ in })
        try await repo.load(); hold = true
        let refresh = Task { try await repo.load(force: true) }
        while held == nil { await Task.yield() }
        let device = FeedbackDeviceInfo(deviceModel: "MacBookAir10,1", osVersion: "macOS 15.6.1", appVersion: "0.1.0 (1)", language: "ru", timeZone: "UTC", capturedAt: "2026-10-09T10:00:00Z")
        _ = try await repo.submit(FeedbackPending(draft: FeedbackDraft(title: "Ошибка списка", message: "Описание ошибки в списке заявок.", areas: [.requests])), slot: UUID(), device: device, expectedContext: context)
        held?.resume(); _ = try? await refresh.value
        XCTAssertEqual(repo.messages.map(\.id), ["fixture-report"])
    }
    func testRefreshStartedBeforeTimedOutAdditionCannotRemoveUncertainty() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "admin-feedback", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let response = try JSONSerialization.data(withJSONObject: ["messages": [root["message"]!]])
        let urlConfig = URLSessionConfiguration.ephemeral; urlConfig.protocolClasses = [FeedbackAsyncProtocol.self]
        let transport = URLSession(configuration: urlConfig)
        defer { transport.invalidateAndCancel(); FeedbackAsyncProtocol.handler = nil }
        var held: CheckedContinuation<Void, Never>?
        var hold = false
        FeedbackAsyncProtocol.handler = { request in
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
            if hold { await withCheckedContinuation { held = $0 } }
            return .init(status: 200, data: response)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScopedSnapshotStorage(root: folder, keyProvider: { _ in Data(repeating: 7, count: 32) })
        let current = AppSession(token: "fixture-token", user: AppUser(id: "fixture-user", email: "fixture@example.invalid", role: "user"))
        let context = SessionContext(epoch: 1, userID: current.user.id, simpleOneUserID: nil)
        let repo = FeedbackRepository(session: { current }, context: { context }, storage: { store }, service: { FeedbackAPI(config: self.config, token: $0.token, httpClient: HTTPClient(session: transport)) }, authFailure: {}, report: { _ in })
        try await repo.load(); hold = true
        let refresh = Task { try await repo.load(force: true) }
        while held == nil { await Task.yield() }
        do { try await repo.add("Уточнение сообщения", id: "fixture-report", expectedContext: context); XCTFail("POST must time out") } catch {}
        XCTAssertTrue(repo.uncertainAdditions.contains("fixture-report"))
        held?.resume(); _ = try? await refresh.value
        XCTAssertTrue(repo.uncertainAdditions.contains("fixture-report"), "Stale GET must not re-enable duplicate additions")
    }
}
