import XCTest
@testable import EngineerCore

@MainActor
final class RouteDraftTests: XCTestCase {
    func testIndependentDaysEditingAndDiscard() {
        let one = RouteDraftController(record: fixtureRoute())
        let two = RouteDraftController(record: fixtureRoute(.pos, date: "2026-10-09"))
        one.updateStop("local-middle", address: "Другой адрес")
        XCTAssertTrue(one.isDirty)
        XCTAssertNil(one.record.stops[1].coordinateOverride)
        XCTAssertNil(one.record.distanceKm)
        XCTAssertEqual(two.record.date, "2026-10-09")
        XCTAssertEqual(two.record.distanceKm, 23)
        one.discard()
        XCTAssertEqual(one.record, fixtureRoute())
        XCTAssertFalse(one.isDirty)
    }
    func testEndpointsCannotBeRemovedOrReorderedAndMiddleMoveInvalidatesMileage() {
        let draft = RouteDraftController(record: fixtureRoute())
        draft.addStop()
        let added = draft.record.stops[2].id
        draft.moveStop(added, offset: -1)
        XCTAssertEqual(draft.record.stops[1].id, added)
        XCTAssertNil(draft.record.distanceKm)
        draft.removeStop("local-start")
        draft.moveStop("local-finish", offset: -1)
        XCTAssertEqual(draft.record.stops.first?.id, "local-start")
        XCTAssertEqual(draft.record.stops.last?.id, "local-finish")
    }
    func testValidationKeepsApril2026AndARMRules() {
        let draft = RouteDraftController(record: fixtureRoute())
        draft.setDistance(nil)
        XCTAssertNotNil(draft.validationMessage)
        draft.setDistance(1); draft.setOdometer(nil)
        XCTAssertNotNil(draft.validationMessage)
        draft.setOdometer(12000)
        XCTAssertNil(draft.validationMessage)
        draft.updateStop("local-middle", address: " ")
        draft.setDistance(1)
        XCTAssertNotNil(draft.validationMessage)
        let historic = RouteDraftController(record: fixtureRoute(.pos, date: "2026-03-31"))
        historic.setDistance(nil); historic.setOdometer(nil)
        XCTAssertNil(historic.validationMessage)
    }
    func testRemoteRefreshDoesNotReplaceDirtyDraft() {
        let draft = RouteDraftController(record: fixtureRoute())
        draft.setDistance(50)
        var remote = fixtureRoute(); remote.distanceKm = 90
        draft.receive(remote: remote)
        XCTAssertEqual(draft.record.distanceKm, 50)
        XCTAssertEqual(draft.remote?.distanceKm, 90)
        XCTAssertTrue(draft.hasRemoteConflict)
    }
    func testReopenedNewDayDraftKeepsAbsentServerBase() {
        let local = fixtureRoute()
        var remote = local; remote.distanceKm = 90
        let saved = RouteSavedDraft(record: local, base: nil, revision: UUID(), queued: false)
        let draft = RouteDraftController(record: remote, remote: remote, draft: saved)
        XCTAssertNil(draft.base)
        XCTAssertTrue(draft.hasRemoteConflict)
        XCTAssertEqual(draft.record.distanceKm, 23)
    }
    func testReopenedDraftDoesNotInventDeletedServerRecord() {
        let local = fixtureRoute()
        let saved = RouteSavedDraft(record: local, base: local, revision: UUID(), queued: false)
        let draft = RouteDraftController(record: local, remote: nil, draft: saved)
        XCTAssertNil(draft.remote)
        XCTAssertTrue(draft.hasRemoteConflict)
        XCTAssertEqual(draft.record, local)
    }

}
