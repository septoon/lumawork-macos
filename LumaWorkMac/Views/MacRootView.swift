import SwiftUI
import EngineerCore

struct MacRootView: View {
    let container: MacSessionContainer
    private var coordinator: EngineerApplicationCoordinator { container.coordinator }

    var body: some View {
        Group {
            if let session = coordinator.session {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.user.profile?.fullName ?? session.user.email).font(.title2.weight(.semibold))
                    Text(session.user.email).foregroundStyle(.secondary)
                    if coordinator.appConnection == .offline {
                        Label("Нет связи с сервером. Используется сохранённая сессия.", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                    if let error = coordinator.appError {
                        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Проверить соединение") { Task { await coordinator.refreshSession() } }
                            .disabled(coordinator.isAuthenticating)
                        Button("Выйти") { Task { await coordinator.logout() } }
                        SettingsLink { Text("Настройки") }
                    }
                    Divider()
                    MacSimpleOneAuthView(coordinator: coordinator)
                    Divider()
                    Text("Рабочие разделы ещё не подключены.").foregroundStyle(.secondary)
                }
                .frame(width: 480, alignment: .leading)
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
        // Clears window-local auth drafts when another window logs in/out.
        .id(coordinator.session?.user.id)
    }
}
