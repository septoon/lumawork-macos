import SwiftUI
import EngineerCore

struct MacSimpleOneAuthView: View {
    let coordinator: EngineerApplicationCoordinator
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SimpleOne").font(.headline)
            if let session = coordinator.simpleOneSession {
                LabeledContent("Пользователь", value: session.user.displayName.isEmpty ? session.user.username : session.user.displayName)
                if coordinator.simpleOneConnection == .offline {
                    Label("SimpleOne недоступен. Сессия сохранена локально.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
                Button("Выйти из SimpleOne") { coordinator.disconnectSimpleOne() }
                    .disabled(coordinator.isSimpleOneAuthenticating)
            } else {
                Text("Вход нужен для заявок и других данных SimpleOne.")
                    .foregroundStyle(.secondary)
                TextField("Логин SimpleOne", text: $username).textContentType(.username)
                SecureField("Пароль", text: $password).textContentType(.password)
                HStack {
                    Button("Войти в SimpleOne") {
                        let login = username
                        let secret = password
                        password = ""
                        Task { _ = await coordinator.loginSimpleOne(username: login, password: secret) }
                    }
                    .disabled(coordinator.isSimpleOneAuthenticating || coordinator.appConnection != .online || username.isEmpty || password.isEmpty)
                    if coordinator.isSimpleOneAuthenticating { ProgressView().controlSize(.small) }
                }
            }
            if let error = coordinator.simpleOneError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 400, alignment: .leading)
        .onDisappear { password = "" }
    }
}
