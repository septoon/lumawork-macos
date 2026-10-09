import SwiftUI
import EngineerCore

struct MacAccountView: View {
    let container: MacSessionContainer
    let profile: MacProfileWorkspace
    private var coordinator: EngineerApplicationCoordinator { container.coordinator }
    private var documents: DocumentsRepository { container.documents }
    let documentsWorkspace: MacDocumentsWorkspace
    @State private var showsDocuments = false
    let logout: () -> Void
    let navigate: (EngineerSection) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Учётная запись").font(.title2.weight(.semibold))
            if let session = coordinator.session {
                Text(session.user.profile?.fullName ?? session.user.email).font(.headline)
                Text(session.user.email).foregroundStyle(.secondary).textSelection(.enabled)
                if coordinator.appConnection == .offline {
                    Label("Нет связи с сервером. Используется сохранённая сессия.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
                if let error = coordinator.appError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                MacSimpleOneAuthView(coordinator: coordinator)
                Button("Профиль…") { profile.isPresented = true }
                Button("Рабочие документы…") { showsDocuments = true }
                Divider()
                HStack {
                    Button("Проверить соединение") { Task { await coordinator.refreshSession() } }
                        .disabled(coordinator.isAuthenticating)
                    Button("Выйти из Инженера", action: logout)
                    Spacer()
                    Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .interactiveDismissDisabled(documentsWorkspace.hasDirty || documentsWorkspace.isBusy || profile.hasDirty || profile.busy || container.profile.isSaving)
        .sheet(isPresented: Binding(get: { profile.isPresented }, set: { profile.isPresented = $0 })) {
            MacProfileView(model: profile, container: container, openDocuments: { Task { if await MacDraftRegistry.shared.confirm() { profile.isPresented = false; showsDocuments = true } } }, openFuel: { navigate(.fuel) }, openVehicles: { navigate(.maintenance) }, openAnalytics: { navigate(.analytics) })
        }
        .sheet(isPresented: $showsDocuments) { MacDocumentsView(model: documentsWorkspace, collection: .work, repository: documents, coordinator: coordinator) }
    }
}
