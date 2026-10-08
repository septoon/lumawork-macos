import Foundation
import Observation
import EngineerCore

@MainActor @Observable
final class MacWorkspaceState {
    let windowID = UUID()
    private(set) var selectedSection = EngineerSection.home
    private(set) var availableSections: [EngineerSection] = []
    var isAccountPresented = false
    private var userID: String?

    func reconcile(user: AppUser?, restoredSection: String? = nil, restoredUserID: String? = nil) {
        guard let user else {
            userID = nil; selectedSection = .home
            availableSections = []; isAccountPresented = false
            return
        }
        let wasUnconfigured = userID == nil
        if userID != user.id {
            selectedSection = .home; isAccountPresented = false
        }
        userID = user.id
        availableSections = EngineerSection.availableCases(isAdmin: user.canAccessAdminPanel)
        if wasUnconfigured, restoredUserID == user.id, let restoredSection {
            select(EngineerSection(rawValue: restoredSection))
        } else if !availableSections.contains(selectedSection) {
            selectedSection = .home
        }
    }

    func select(_ section: EngineerSection?) {
        selectedSection = section.flatMap { availableSections.contains($0) ? $0 : nil } ?? .home
    }
}

// The focused scene supplies this target. Permissions are read again at dispatch time.
@MainActor
struct MacWorkspaceNavigation {
    let state: MacWorkspaceState
    let currentUser: () -> AppUser?
    var requestSelection: ((EngineerSection) -> Void)? = nil

    func select(_ section: EngineerSection) {
        state.reconcile(user: currentUser())
        if let requestSelection { requestSelection(section) } else { state.select(section) }
    }
}
