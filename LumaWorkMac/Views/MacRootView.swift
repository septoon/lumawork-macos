import SwiftUI
import EngineerCore

struct MacRootView: View {
    let container: MacSessionContainer
    @SceneStorage("EngineerMac.workspace.section") private var restoredSection = EngineerSection.home.rawValue
    @SceneStorage("EngineerMac.workspace.owner") private var restoredUserID = ""
    private var coordinator: EngineerApplicationCoordinator { container.coordinator }

    var body: some View {
        Group {
            if let session = coordinator.session {
                MacWorkspaceView(container: container, restoredSection: $restoredSection, restoredUserID: $restoredUserID)
                    .id(session.user.id)
            } else if coordinator.appConnection == .restoring {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Восстановление сессии…").foregroundStyle(.secondary)
                    Button("Выйти") { Task { await coordinator.logout() } }
                }
            } else {
                VStack(spacing: 16) {
                    MacAuthView(coordinator: coordinator)
                    if coordinator.appConnection == .failed {
                        HStack {
                            Button("Повторить восстановление") {
                                Task { await coordinator.retryRestore() }
                            }
                            Button("Удалить сохранённую сессию") {
                                Task { await coordinator.logout() }
                            }
                        }
                        .disabled(coordinator.isAuthenticating)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 1000, minHeight: 640)
        .navigationTitle("Инженер")
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .onAppear { container.start() }
        .onChange(of: coordinator.session?.user.id) { oldID, newID in
            if oldID != nil, oldID != newID {
                restoredSection = EngineerSection.home.rawValue
                restoredUserID = newID ?? ""
            }
        }
    }
}
