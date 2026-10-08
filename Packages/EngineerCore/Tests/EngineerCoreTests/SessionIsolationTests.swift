import XCTest
@testable import EngineerCore

@MainActor
final class SessionIsolationTests: XCTestCase {
    private let userA = AppUser(id: "A", email: "a@example.invalid", role: "engineer")
    private let userB = AppUser(id: "B", email: "b@example.invalid", role: "engineer")

    func testLateResponseDiscardedAfterAccountSwitch() async throws {
        let api = TestAppAuth()
        let vault = TestCredentials()
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        let pending = Task { await coordinator.verifyCode(email: "a@example.invalid", code: "000000") }
        await api.waitForVerification()
        await coordinator.logout()
        api.holdVerification = false
        api.verified = AppSession(token: "token-B", user: userB)
        let signedIn = await coordinator.verifyCode(email: "b@example.invalid", code: "000000")
        XCTAssertTrue(signedIn)
        let contextB = try XCTUnwrap(coordinator.context)
        api.releaseVerification(AppSession(token: "token-A", user: userA))
        _ = await pending.value
        XCTAssertEqual(coordinator.session?.user.id, "B")
        XCTAssertEqual(vault.value?.app.user.id, "B")
        XCTAssertTrue(coordinator.accepts(contextB))
    }

    func test401DoesNotReturnProtectedCache() async throws {
        let api = TestAppAuth(); api.current = userA
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        let oldContext = try XCTUnwrap(coordinator.context)
        api.currentError = AppServiceError.http(status: 401, fallback: "Auth")
        await coordinator.refreshSession()
        XCTAssertNil(coordinator.session)
        XCTAssertNil(coordinator.context)
        XCTAssertFalse(coordinator.accepts(oldContext))
        XCTAssertNil(vault.value)
        XCTAssertEqual(coordinator.appConnection, .signedOut)
    }

    func testOfflineRestoreKeepsOnlyKnownIdentity() async {
        let api = TestAppAuth(); api.currentError = URLError(.notConnectedToInternet)
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        XCTAssertEqual(coordinator.appConnection, .offline)
        XCTAssertEqual(coordinator.session?.user.id, "A")
        XCTAssertEqual(coordinator.simpleOneConnection, .signedOut)
    }

    func testMalformedRestoreDoesNotBecomeOfflineSuccess() async {
        let api = TestAppAuth(); api.currentError = AppServiceError.message("Malformed response")
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        XCTAssertEqual(coordinator.appConnection, .failed)
        XCTAssertNil(coordinator.session)
        XCTAssertNil(coordinator.context)
        XCTAssertNotNil(vault.value)
    }

    func testLogoutClearsLocalAccessBeforeNetworkRevocationCompletes() async {
        let api = TestAppAuth(); api.current = userA; api.holdLogout = true
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        let logout = Task { await coordinator.logout() }
        await api.waitForLogout()
        XCTAssertNil(coordinator.session)
        XCTAssertNil(vault.value)
        api.releaseLogout()
        await logout.value
    }

    func testExpiredSODoesNotInvalidateAppSession() async {
        let api = TestAppAuth(); api.current = userA
        let so = TestSOAuth(); so.error = SimpleOneServiceError.unauthorized
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        vault.value?.simpleOne = SimpleOneSession(authKey: "so-key", user: SimpleOneUser(sysID: "SO-A", username: "a", firstName: "", lastName: ""))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: so, credentials: vault)
        await coordinator.restore()
        XCTAssertEqual(coordinator.appConnection, .online)
        XCTAssertEqual(coordinator.session?.user.id, "A")
        XCTAssertNil(coordinator.simpleOneSession)
        XCTAssertNil(vault.value?.simpleOne)
        XCTAssertNotNil(coordinator.simpleOneError)
        XCTAssertNil(coordinator.appError)
    }

    func testCredentialsWriteFailureDoesNotAuthenticate() async {
        let api = TestAppAuth(); api.holdVerification = false; api.verified = AppSession(token: "token-A", user: userA)
        let vault = TestCredentials(); vault.writeError = CocoaError(.fileWriteOutOfSpace)
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        let result = await coordinator.verifyCode(email: "a@example.invalid", code: "000000")
        XCTAssertFalse(result)
        XCTAssertNil(coordinator.session)
        XCTAssertNotNil(coordinator.appError)
    }

    func test403AndRevokedAccessDoNotRestoreAnOfflineAccount() async {
        for error in [AppServiceError.http(status: 403, fallback: "Forbidden") as Error, LumaWorkAuthError.accessRevoked] {
            let api = TestAppAuth(); api.currentError = error
            let vault = TestCredentials(AppSession(token: "token-A", user: userA))
            let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
            await coordinator.restore()
            XCTAssertNil(coordinator.session)
            XCTAssertNil(vault.value)
            XCTAssertEqual(coordinator.appConnection, .signedOut)
        }
    }

    func testEmptyPersistedIdentityCannotOpenOfflineStorage() async {
        let api = TestAppAuth(); api.currentError = URLError(.notConnectedToInternet)
        let vault = TestCredentials(AppSession(token: "", user: AppUser(id: "", email: "", role: "engineer")))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        XCTAssertNil(coordinator.session)
        XCTAssertNil(coordinator.context)
        XCTAssertNil(vault.value)
    }

    func testDisconnectSODuringAppRefreshDoesNotStrandOrRestoreCredentials() async {
        let api = TestAppAuth(); api.current = userA
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        vault.value?.simpleOne = SimpleOneSession(authKey: "so-key", user: SimpleOneUser(sysID: "SO-A", username: "a", firstName: "", lastName: ""))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        api.holdCurrent = true
        let refresh = Task { await coordinator.refreshSession() }
        await api.waitForCurrent()
        coordinator.disconnectSimpleOne()
        api.releaseCurrent(userA)
        await refresh.value
        XCTAssertEqual(coordinator.appConnection, .online)
        XCTAssertNotNil(coordinator.context)
        XCTAssertNil(coordinator.simpleOneSession)
        XCTAssertNil(vault.value?.simpleOne)
    }

    func testForbiddenSOIdentityCannotReappearFromOfflineCache() async {
        let api = TestAppAuth(); api.current = userA
        let replies = SOReplies()
        let transport = FixtureURLProtocol.install { _ in try replies.response() }
        defer { transport.invalidateAndCancel() }
        let so = SimpleOneAuthAPI(config: AppConfig(simpleOneAPIOrigin: "https://so.example.invalid"), session: transport)
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        vault.value?.simpleOne = SimpleOneSession(authKey: "so-key", user: SimpleOneUser(sysID: "SO-A", username: "a", firstName: "", lastName: ""))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: so, credentials: vault)
        await coordinator.restore()
        replies.setStatus(403)
        await coordinator.refreshSimpleOne()
        replies.setStatus(-1)
        await coordinator.refreshSimpleOne()
        XCTAssertNil(coordinator.simpleOneSession)
        XCTAssertNil(vault.value?.simpleOne)
        XCTAssertNil(coordinator.context?.simpleOneUserID)
        XCTAssertEqual(coordinator.appConnection, .online)
    }

    func testEmptySOIdentityDoesNotCreateAnOfflineSOContext() async {
        let api = TestAppAuth(); api.current = userA
        let so = TestSOAuth(); so.error = URLError(.notConnectedToInternet)
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        vault.value?.simpleOne = SimpleOneSession(authKey: "", user: SimpleOneUser(sysID: "", username: "", firstName: "", lastName: ""))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: so, credentials: vault)
        await coordinator.restore()
        XCTAssertNil(coordinator.simpleOneSession)
        XCTAssertNil(vault.value?.simpleOne)
        XCTAssertEqual(coordinator.appConnection, .online)
    }

    func testWakeRefreshesAreSingleFlight() async {
        let api = TestAppAuth(); api.current = userA
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        api.holdCurrent = true
        let wakeA = Task { await coordinator.resumeAfterWake() }
        await api.waitForCurrent()
        let wakeB = Task { await coordinator.resumeAfterWake() }
        await Task.yield()
        api.releaseCurrent(userA)
        await wakeA.value; await wakeB.value
        XCTAssertEqual(api.currentCalls, 2) // restore, then exactly one wake request
        XCTAssertEqual(coordinator.appConnection, .online)
    }

    func testChangedServerIdentityDoesNotReuseSOPermissions() async {
        let api = TestAppAuth(); api.current = userB
        let vault = TestCredentials(AppSession(token: "token-A", user: userA))
        let coordinator = EngineerApplicationCoordinator(appAPI: api, simpleOneAPI: TestSOAuth(), credentials: vault)
        await coordinator.restore()
        XCTAssertNil(coordinator.session)
        XCTAssertNil(vault.value)
    }
}

@MainActor
final class TestCredentials: SessionCredentialStorage {
    var value: SessionCredentials?
    var writeError: Error?
    init(_ app: AppSession? = nil) { value = app.map { SessionCredentials(app: $0) } }
    func read() throws -> SessionCredentials? { value }
    func write(_ credentials: SessionCredentials) throws {
        if let writeError { throw writeError }
        value = credentials
    }
    func delete() throws { value = nil }
}

@MainActor
final class TestAppAuth: AppAuthenticating {
    var current = AppUser(id: "A", email: "a@example.invalid", role: "engineer")
    var currentError: Error?
    var currentCalls = 0
    var holdCurrent = false
    private var currentContinuation: CheckedContinuation<AppUser, Never>?
    private var currentStarted: CheckedContinuation<Void, Never>?
    var verified: AppSession?
    var holdVerification = true
    var holdLogout = false
    private var verifyContinuation: CheckedContinuation<AppSession, Error>?
    private var verifyStarted: CheckedContinuation<Void, Never>?
    private var logoutContinuation: CheckedContinuation<Void, Never>?
    private var logoutStarted: CheckedContinuation<Void, Never>?
    func requestCode(email: String) async throws {}
    func verifyCode(email: String, code: String) async throws -> AppSession {
        if !holdVerification { return verified! }
        return try await withCheckedThrowingContinuation {
            verifyContinuation = $0
            verifyStarted?.resume(); verifyStarted = nil
        }
    }
    func currentUser(token: String) async throws -> AppUser {
        currentCalls += 1
        if let currentError { throw currentError }
        if holdCurrent {
            return await withCheckedContinuation {
                currentContinuation = $0
                currentStarted?.resume(); currentStarted = nil
            }
        }
        return current
    }
    func logout(token: String) async throws {
        if !holdLogout { return }
        await withCheckedContinuation {
            logoutContinuation = $0
            logoutStarted?.resume(); logoutStarted = nil
        }
    }
    func waitForCurrent() async {
        if currentContinuation != nil { return }
        await withCheckedContinuation { currentStarted = $0 }
    }
    func releaseCurrent(_ user: AppUser) { currentContinuation?.resume(returning: user); currentContinuation = nil }
    func waitForVerification() async {
        if verifyContinuation != nil { return }
        await withCheckedContinuation { verifyStarted = $0 }
    }
    func releaseVerification(_ value: AppSession) { verifyContinuation?.resume(returning: value); verifyContinuation = nil }
    func waitForLogout() async {
        if logoutContinuation != nil { return }
        await withCheckedContinuation { logoutStarted = $0 }
    }
    func releaseLogout() { logoutContinuation?.resume(); logoutContinuation = nil }
}

@MainActor
final class TestSOAuth: SimpleOneAuthenticating {
    var error: Error?
    func login(username: String, password: String) async throws -> String { "so-key" }
    func currentUser(authKey: String) async throws -> SimpleOneUser {
        if let error { throw error }
        return SimpleOneUser(sysID: "SO-A", username: "a", firstName: "", lastName: "")
    }
}

private final class SOReplies {
    private let lock = NSLock()
    private var status = 200
    func setStatus(_ value: Int) { lock.lock(); status = value; lock.unlock() }
    func response() throws -> FixtureURLProtocol.Reply {
        lock.lock(); let value = status; lock.unlock()
        if value == -1 { throw URLError(.notConnectedToInternet) }
        return .init(status: value, data: Data(#"{"status":"OK","data":{"sys_id":"SO-A","username":"a","first_name":"","last_name":""}}"#.utf8))
    }
}
