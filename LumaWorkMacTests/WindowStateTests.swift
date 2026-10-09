import XCTest
import EngineerCore

@MainActor
final class WindowStateTests: XCTestCase {
    private let engineer = AppUser(id: "synthetic-A", email: "a@example.invalid", role: "engineer")
    private let admin = AppUser(id: "synthetic-A", email: "a@example.invalid", role: "admin", adminPermissions: ["users.view"])

    func testDiscardAwaitsLocalPersistenceBeforeCheckingDraftAgain() async {
        var dirty = true, decisions = 0
        let entry = MacDraftRegistry.Entry(window: nil, hasDirty: { dirty }, save: {}, discard: {
            await Task.yield(); dirty = false
        }, discardOnly: { true })
        let accepted = await MacDraftRegistry.resolve(entry, decision: { _ in
            decisions += 1; return decisions == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn
        }, failed: { _ in XCTFail("Discard must not fail") })
        XCTAssertTrue(accepted); XCTAssertEqual(decisions, 1); XCTAssertFalse(dirty)
    }
    func testDiscardPersistenceFailureKeepsWindowOpen() async {
        let entry = MacDraftRegistry.Entry(window: nil, hasDirty: { true }, save: {}, discard: { throw NSError(domain: "fixture", code: 1) }, discardOnly: { true })
        var failed = false
        let accepted = await MacDraftRegistry.resolve(entry, decision: { _ in .alertFirstButtonReturn }, failed: { _ in failed = true })
        XCTAssertFalse(accepted); XCTAssertTrue(failed)
    }
    func testTwoWindowsKeepIndependentSelection() {
        let a = MacWorkspaceState(); let b = MacWorkspaceState()
        a.reconcile(user: engineer); b.reconcile(user: engineer)
        a.select(.requests); b.select(.fuel)
        XCTAssertEqual(a.selectedSection, .requests)
        XCTAssertEqual(b.selectedSection, .fuel)
        XCTAssertNotEqual(a.windowID, b.windowID)
    }

    func testRestorationRejectsUnknownUnauthorizedAndOtherAccountSections() {
        for raw in ["missing", "users"] {
            let state = MacWorkspaceState()
            state.reconcile(user: engineer, restoredSection: raw, restoredUserID: "synthetic-A")
            XCTAssertEqual(state.selectedSection, .home)
        }
        let sameAccount = MacWorkspaceState()
        sameAccount.reconcile(user: engineer, restoredSection: "requests", restoredUserID: "synthetic-A")
        XCTAssertEqual(sameAccount.selectedSection, .requests)
        let otherAccount = MacWorkspaceState()
        otherAccount.reconcile(user: engineer, restoredSection: "salary", restoredUserID: "synthetic-B")
        XCTAssertEqual(otherAccount.selectedSection, .home)
    }

    func testCommandTargetsItsWindowAndRechecksCurrentPermissions() {
        let a = MacWorkspaceState(); let b = MacWorkspaceState()
        var currentUser: AppUser? = admin
        a.reconcile(user: admin); b.reconcile(user: admin)
        let targetA = MacWorkspaceNavigation(state: a, currentUser: { currentUser })
        let targetB = MacWorkspaceNavigation(state: b, currentUser: { currentUser })
        targetA.select(.users)
        targetB.select(.requests)
        XCTAssertEqual(a.selectedSection, .users)
        XCTAssertEqual(b.selectedSection, .requests)
        currentUser = engineer
        targetA.select(.users)
        XCTAssertEqual(a.selectedSection, .home)
        XCTAssertEqual(b.selectedSection, .requests)
        currentUser = nil
        targetB.select(.fuel)
        XCTAssertEqual(b.selectedSection, .home)
        XCTAssertTrue(b.availableSections.isEmpty)
    }

    func testAccountSwitchAndLogoutResetWindowPresentation() {
        let state = MacWorkspaceState()
        state.reconcile(user: admin)
        state.select(.salary); state.isAccountPresented = true
        state.reconcile(user: AppUser(id: "synthetic-B", email: "b@example.invalid", role: "engineer"))
        XCTAssertEqual(state.selectedSection, .home)
        XCTAssertFalse(state.isAccountPresented)
        state.select(.requests); state.isAccountPresented = true
        state.reconcile(user: nil)
        XCTAssertEqual(state.selectedSection, .home)
        XCTAssertFalse(state.isAccountPresented)
        XCTAssertTrue(state.availableSections.isEmpty)
    }

    func testAdminRoleWithoutGrantedPermissionsCannotOpenAdminSection() {
        let state = MacWorkspaceState()
        state.reconcile(user: AppUser(id: "synthetic-A", email: "a@example.invalid", role: "admin", adminPermissions: []),
                        restoredSection: "users", restoredUserID: "synthetic-A")
        XCTAssertEqual(state.selectedSection, .home)
        XCTAssertFalse(state.availableSections.contains(.users))
    }
}
