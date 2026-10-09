import SwiftUI
import EngineerCore
import LocalAuthentication
import AppKit

enum MacAdminPage: String, CaseIterable, Identifiable {
    case overview, audit, users, feedback
    var id: String { rawValue }
    var title: String { switch self { case .overview: "Сводка"; case .audit: "Журнал действий"; case .users: "Пользователи"; case .feedback: "Обратная связь" } }
    var icon: String { switch self { case .overview: "gauge.with.dots.needle.33percent"; case .audit: "list.bullet.rectangle"; case .users: "person.2"; case .feedback: "bubble.left.and.bubble.right" } }
    var permission: AdminPermission { switch self { case .overview: .viewOverview; case .audit: .viewAuditLog; case .users: .viewUsers; case .feedback: .viewFeedback } }
}
struct MacAdminUserEditor: Identifiable {
    enum Action: String { case block, unblock, access, delete, notify }
    let id = UUID()
    let action: Action
    let user: AdminUserRecord?
}
@MainActor @Observable final class MacAdminWorkspace {
    var grant: ProtectedAccessGrant?
    var authenticating = false
    var authError: String?
    var isVisible = false
    private var authenticationID: UUID?
    private var system: LAContext?
    var page: MacAdminPage = .overview
    var userID: String?
    var feedbackID: String?
    var search = ""
    var onlyBlocked = false
    var feedbackStatus: FeedbackStatus?
    var feedbackKind: FeedbackKind?
    var editor: MacAdminUserEditor?
    var feedbackEditorID: String?
    var preview: MacDocumentPreviewItem?
    private var previewFile: URL?
    var hasDirty: Bool { editor != nil || feedbackEditorID != nil }
    func reset() { authenticationID = nil; system?.invalidate(); system = nil; authenticating = false; isVisible = false; grant = nil; authError = nil; page = .overview; userID = nil; feedbackID = nil; search = ""; onlyBlocked = false; feedbackStatus = nil; feedbackKind = nil; editor = nil; feedbackEditorID = nil; cleanPreview() }
    func lock(container: MacSessionContainer, cancelAuthentication: Bool = true) {
        container.adminAccess.revoke(grant); grant = nil; editor = nil; feedbackEditorID = nil; userID = nil; feedbackID = nil; cleanPreview()
        if cancelAuthentication { authenticationID = nil; system?.invalidate(); system = nil; authenticating = false }
    }
    func authenticate(container: MacSessionContainer) async {
        guard isVisible, !authenticating, NSApp.isActive, let context = container.coordinator.context, container.coordinator.session?.user.canAccessAdminPanel == true else { return }
        let id = UUID(), hardGeneration = container.coordinator.protectedAuthenticationGeneration
        authenticationID = id; authenticating = true; authError = nil
        let system = LAContext(); self.system = system; system.localizedCancelTitle = "Отмена"
        defer { if authenticationID == id { authenticating = false; self.system = nil } }
        do {
            guard system.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { throw AppServiceError.message("Для входа настройте Touch ID или пароль Mac.") }
            let verified = try await system.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Открыть админку")
            guard verified else { throw CancellationError() }
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
            while true {
                try Task.checkCancellation()
                guard authenticationID == id, isVisible, container.coordinator.accepts(context), container.coordinator.protectedAuthenticationGeneration == hardGeneration else { throw CancellationError() }
                if NSApp.isActive { break }; guard clock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(20))
            }
            editor = nil; feedbackEditorID = nil; userID = nil; feedbackID = nil; cleanPreview()
            container.admin.synchronizeSession()
            grant = try container.adminAccess.authorize(expectedContext: context, expectedGeneration: container.coordinator.protectedContentGeneration)
        } catch { if authenticationID == id, isVisible, container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { authError = error.localizedDescription } }
    }
    func presentPreview(_ item: MacDocumentPreviewItem) { cleanPreview(); previewFile = item.url; preview = item }
    func cleanPreview() { if let file = previewFile { MacImageAdapter.remove(file: file); try? FileManager.default.removeItem(at: file) }; previewFile = nil; preview = nil }
}
