import SwiftUI
import EngineerCore

struct MacAccountView: View {
    let coordinator: EngineerApplicationCoordinator
    let documents: DocumentsRepository
    let documentsWorkspace: MacDocumentsWorkspace
    @State private var showsDocuments = false
    let logout: () -> Void
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
        .interactiveDismissDisabled(documentsWorkspace.hasDirty || documentsWorkspace.isBusy)
        .sheet(isPresented: $showsDocuments) { MacDocumentsView(model: documentsWorkspace, collection: .work, repository: documents, coordinator: coordinator) }
    }
}
