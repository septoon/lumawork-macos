import XCTest
@testable import EngineerCore

@MainActor
private final class RouteWriteGate {
    var holdNext = false
    var suspended: CheckedContinuation<Data, Never>?
    func key() async -> Data {
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { suspended = $0 }
        }
        return Data(repeating: 9, count: 32)
    }
}

@MainActor
private final class RouteServerFixture: RouteDayServing {
    var remote: RouteDayRecord? = fixtureRoute()
    var fetchCount = 0
    var sendCount = 0
    var error: Error?
    var suspended: CheckedContinuation<RouteDayRecord?, Error>?
    var hold = false
    var holdSend = false
    var sendSuspended: CheckedContinuation<Void, Never>?
    var holdArchive = false
    var archiveSuspended: CheckedContinuation<[RouteDayRecord], Error>?
    var onSend: (() -> Void)?
    func fetchDay(date: String, workType: RouteWorkType, settings: RouteSettings) async throws -> RouteDayRecord? {
        fetchCount += 1
        if let error { throw error }
        if hold { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return remote?.key == RouteDayKey(date: date, workType: workType) ? remote : nil
    }
    func fetchAllDays(settings: RouteSettings) async throws -> [RouteDayRecord] {
        if let error { throw error }
        if holdArchive { return try await withCheckedThrowingContinuation { archiveSuspended = $0 } }
        return remote.map { [$0] } ?? []
    }
    func fetchOfficeAddresses() async throws -> [String] { [] }
    func sendDay(_ record: RouteDayRecord, date: String, settings: RouteSettings) async throws -> RouteDayRecord {
        sendCount += 1
        if let error { throw error }
        var result = record // The existing upsert echoes submitted sent=false.
        for i in result.stops.indices { result.stops[i].id = "upsert-\(i)" }
        if holdSend { await withCheckedContinuation { sendSuspended = $0 } }
        remote = result
        onSend?()
        return result
    }
}

@MainActor
final class RouteRepositoryTests: XCTestCase {
    private var session = AppSession(token: "fixture-token", user: AppUser(id: "route-A", email: "a@example.invalid", role: "engineer"))
    private var context: SessionContext? = SessionContext(epoch: 1, userID: "route-A", simpleOneUserID: nil)
    private func setup(_ server: RouteServerFixture) throws -> (RouteDayRepository, ScopedSnapshotStorage, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 9, count: 32) })
        let repo = RouteDayRepository(session: { self.context == nil ? nil : self.session }, context: { self.context }, storage: { storage }, service: { _ in server })
        return (repo, storage, root)
    }

    func testSavedDraftSurvivesRelaunchAndNetworkFailure() async throws {
        let server = RouteServerFixture()
        let (repo, storage, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = fixtureRoute().key
        _ = try await repo.load(key)
        var draft = fixtureRoute(); draft.distanceKm = 44
        let saved = try await repo.saveLocal(draft, base: fixtureRoute(), replacing: nil)
        XCTAssertEqual(saved.record.distanceKm, 44)
        server.error = RouteDayServiceError.infrastructure("Нет сети")
        let restored = RouteDayRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in server })
        _ = try? await restored.load(key)
        XCTAssertEqual(restored.snapshot(for: key)?.draft?.record.distanceKm, 44)
        XCTAssertEqual(restored.snapshot(for: key)?.remote?.distanceKm, 23)
        XCTAssertEqual(restored.snapshot(for: key)?.connection, .offline)
    }

    func testRemoteConflictDoesNotSubmitOrReplaceLocalDraft() async throws {
        let server = RouteServerFixture()
        let (repo, _, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        var changed = fixtureRoute(); changed.distanceKm = 42
        _ = try await repo.saveLocal(changed, base: fixtureRoute(), replacing: nil)
        server.remote?.distanceKm = 90
        do { _ = try await repo.send(changed, base: fixtureRoute()); XCTFail("Conflict sent") }
        catch RouteRepositoryError.conflict { }
        XCTAssertEqual(server.sendCount, 0)
        XCTAssertEqual(repo.snapshot(for: changed.key)?.draft?.record.distanceKm, 42)
    }

    func testParallelWindowDraftSaveCannotSilentlyOverwriteNewerRevision() async throws {
        let server = RouteServerFixture()
        let (repo, _, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        var one = fixtureRoute(); one.distanceKm = 10
        _ = try await repo.saveLocal(one, base: fixtureRoute(), replacing: nil)
        var two = fixtureRoute(); two.distanceKm = 20
        do { _ = try await repo.saveLocal(two, base: fixtureRoute(), replacing: nil); XCTFail("Silent overwrite") }
        catch RouteRepositoryError.localConflict { }
        XCTAssertEqual(repo.snapshot(for: one.key)?.draft?.record.distanceKm, 10)
    }

    func testExplicitAdoptionOfOtherWindowDraftAllowsFurtherSave() async throws {
        let (repo, _, root) = try setup(RouteServerFixture())
        defer { try? FileManager.default.removeItem(at: root) }
        let windowB = RouteDraftController(record: fixtureRoute())
        windowB.setDistance(20)
        var windowA = fixtureRoute(); windowA.distanceKm = 10
        let savedA = try await repo.saveLocal(windowA, base: fixtureRoute(), replacing: nil)
        // Refresh does not discard B's edits; only explicit adoption does.
        windowB.receive(remote: fixtureRoute())
        XCTAssertEqual(windowB.record.distanceKm, 20)
        windowB.useSavedDraft(savedA)
        XCTAssertEqual(windowB.record.distanceKm, 10)
        XCTAssertFalse(windowB.isDirty)
        windowB.setDistance(30)
        let savedB = try await repo.saveLocal(windowB.record, base: windowB.base, replacing: windowB.savedRevision)
        XCTAssertEqual(savedB.record.distanceKm, 30)
    }

    func testLateAccountResponseCannotPublishOrPersist() async throws {
        let server = RouteServerFixture(); server.hold = true
        let (repo, storage, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await repo.load(fixtureRoute().key) }
        while server.suspended == nil { await Task.yield() }
        context = SessionContext(epoch: 2, userID: "route-B", simpleOneUserID: nil)
        session.user.id = "route-B"
        repo.synchronizeSession()
        server.suspended?.resume(returning: fixtureRoute()); server.suspended = nil
        do { _ = try await task.value; XCTFail("Late response accepted") } catch { }
        XCTAssertNil(repo.snapshot(for: fixtureRoute().key))
        let dataA = try await storage.load(key: "routes.v1", scope: SnapshotScope(userID: "route-A"))
        let dataB = try await storage.load(key: "routes.v1", scope: SnapshotScope(userID: "route-B"))
        XCTAssertNil(dataA); XCTAssertNil(dataB)
    }

    func test401ClearsCacheAccessAndDoesNotQueue() async throws {
        let server = RouteServerFixture()
        let (repo, _, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        server.error = RouteDayServiceError.unauthorized
        do { _ = try await repo.load(fixtureRoute().key, force: true); XCTFail("401 accepted") } catch { }
        XCTAssertNil(repo.snapshot(for: fixtureRoute().key)?.remote)
        XCTAssertTrue(repo.requiresAuthentication)
    }

    func testSuccessfulSendUsesServerIDsAndClearsOnlyMatchingDraft() async throws {
        let server = RouteServerFixture()
        let (repo, _, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        var record = fixtureRoute(); record.distanceKm = 80
        _ = try await repo.saveLocal(record, base: fixtureRoute(), replacing: nil)
        let result = try await repo.send(record, base: fixtureRoute())
        XCTAssertEqual(result.stops[1].id, "upsert-1")
        XCTAssertTrue(result.sent)
        XCTAssertNil(repo.snapshot(for: record.key)?.draft)
        XCTAssertEqual(repo.snapshot(for: record.key)?.remote?.distanceKm, 80)
    }
    func testGetStartedDuringSendCannotReplaceConfirmedRouteOrCancelOtherDay() async throws {
        let server = RouteServerFixture()
        let (repo, _, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        var changed = fixtureRoute(); changed.distanceKm = 80
        server.holdSend = true
        let sending = Task { try await repo.send(changed, base: fixtureRoute()) }
        while server.sendSuspended == nil { await Task.yield() }
        server.hold = true
        let lateGET = Task { try await repo.load(changed.key, force: true) }
        while server.suspended == nil { await Task.yield() }
        server.holdArchive = true
        let lateArchive = Task { try await repo.loadArchive(force: true) }
        while server.archiveSuspended == nil { await Task.yield() }
        server.hold = false
        let otherKey = RouteDayKey(date: "2026-10-09", workType: .pos)
        _ = try await repo.load(otherKey)
        XCTAssertEqual(repo.snapshot(for: otherKey)?.connection, .online)
        server.sendSuspended?.resume(); server.sendSuspended = nil
        _ = try await sending.value
        server.suspended?.resume(returning: fixtureRoute()); server.suspended = nil
        do { _ = try await lateGET.value; XCTFail("Stale GET accepted") } catch { }
        server.archiveSuspended?.resume(returning: [fixtureRoute()]); server.archiveSuspended = nil
        do { try await lateArchive.value; XCTFail("Stale archive accepted") } catch { }
        XCTAssertEqual(repo.snapshot(for: changed.key)?.remote?.distanceKm, 80)
        XCTAssertEqual(repo.snapshot(for: otherKey)?.connection, .online)
    }
    func testGetWaitingForPersistenceDoesNotReturnStaleRecordAfterSend() async throws {
        let server = RouteServerFixture()
        let gate = RouteWriteGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in await gate.key() })
        let repo = RouteDayRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in server })
        _ = try await repo.load(fixtureRoute().key)
        var changed = fixtureRoute(); changed.distanceKm = 80
        _ = try await repo.saveLocal(changed, base: fixtureRoute(), replacing: nil)
        server.holdSend = true
        let sending = Task { try await repo.send(changed, base: fixtureRoute()) }
        while server.sendSuspended == nil { await Task.yield() }
        gate.holdNext = true
        let loading = Task { try await repo.load(changed.key, force: true) }
        while gate.suspended == nil { await Task.yield() }
        server.sendSuspended?.resume(); server.sendSuspended = nil
        while repo.snapshot(for: changed.key)?.remote?.distanceKm != 80 { await Task.yield() }
        gate.suspended?.resume(returning: Data(repeating: 9, count: 32)); gate.suspended = nil
        _ = try await sending.value
        do { _ = try await loading.value; XCTFail("Stale record returned to window after persist") } catch { }
        XCTAssertEqual(repo.snapshot(for: changed.key)?.remote?.distanceKm, 80)
    }
    func testOfflineSendIsDurableAndReadbackRetryDoesNotDuplicateWrite() async throws {
        let server = RouteServerFixture()
        let (repo, storage, root) = try setup(server)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.load(fixtureRoute().key)
        var changed = fixtureRoute(); changed.distanceKm = 66
        server.error = RouteDayServiceError.infrastructure("Нет сети")
        do { _ = try await repo.send(changed, base: fixtureRoute()); XCTFail("Offline marked successful") }
        catch RouteRepositoryError.queued { }
        let reopened = RouteDayRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in server })
        let cached = try await reopened.prepare(changed.key)
        XCTAssertEqual(cached?.draft?.queued, true)
        XCTAssertEqual(cached?.draft?.record.distanceKm, 66)
        server.error = nil
        // A previous uncertain write already reached the server.
        server.remote = changed
        let confirmed = try await reopened.send(changed, base: fixtureRoute())
        XCTAssertEqual(confirmed.distanceKm, 66)
        XCTAssertEqual(server.sendCount, 0)
        XCTAssertNil(reopened.snapshot(for: changed.key)?.draft)
    }

    func testFailedDiscardKeepsSavedDraftAvailable() async throws {
        let server = RouteServerFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 9, count: 32) })
        var denyStorage = false
        let repo = RouteDayRepository(session: { self.session }, context: { self.context }, storage: {
            if denyStorage { throw CocoaError(.fileWriteOutOfSpace) }
            return storage
        }, service: { _ in server })
        let saved = try await repo.saveLocal(fixtureRoute(), base: nil, replacing: nil)
        denyStorage = true
        do { try await repo.discardLocal(saved.record.key, revision: saved.revision); XCTFail("Failed discard accepted") } catch { }
        XCTAssertEqual(repo.snapshot(for: saved.record.key)?.draft, saved)
        denyStorage = false
        try await repo.discardLocal(saved.record.key, revision: saved.revision)
        XCTAssertNil(repo.snapshot(for: saved.record.key)?.draft)
    }

    func testFailedPersistenceAfterPostKeepsDraftRevisionForRecovery() async throws {
        let server = RouteServerFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 9, count: 32) })
        var denyStorage = false
        let repo = RouteDayRepository(session: { self.session }, context: { self.context }, storage: {
            if denyStorage { throw CocoaError(.fileWriteOutOfSpace) }
            return storage
        }, service: { _ in server })
        var changed = fixtureRoute(); changed.distanceKm = 80
        let saved = try await repo.saveLocal(changed, base: fixtureRoute(), replacing: nil)
        server.onSend = { denyStorage = true }
        do { _ = try await repo.send(changed, base: fixtureRoute()); XCTFail("Failed persistence accepted") } catch { }
        XCTAssertEqual(repo.snapshot(for: changed.key)?.draft, saved)
        XCTAssertEqual(repo.snapshot(for: changed.key)?.remote?.distanceKm, 80)
        denyStorage = false
        _ = try await repo.saveLocal(changed, base: saved.base, replacing: saved.revision)
    }

    func testFailedLocalWriteDoesNotClaimSavedRevision() async throws {
        let server = RouteServerFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ScopedSnapshotStorage(root: root, keyProvider: { _ in Data(repeating: 9, count: 32) }, writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let repo = RouteDayRepository(session: { self.session }, context: { self.context }, storage: { storage }, service: { _ in server })
        do { _ = try await repo.saveLocal(fixtureRoute(), base: nil, replacing: nil); XCTFail("Failed disk write accepted") } catch { }
        XCTAssertNil(repo.snapshot(for: fixtureRoute().key)?.draft)
    }

}
