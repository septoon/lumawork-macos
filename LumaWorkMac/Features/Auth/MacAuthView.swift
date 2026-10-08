import SwiftUI
import EngineerCore

struct MacAuthView: View {
    let coordinator: EngineerApplicationCoordinator
    // Credentials entered by the user belong to this window and are never restored.
    @State private var email = ""
    @State private var code = ""
    @State private var codeEmail: String?
    @FocusState private var focus: Field?
    private enum Field { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Вход в Инженер").font(.title2.weight(.semibold))
            Text("Введите рабочую почту. Мы отправим код для входа.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Почта")
                TextField("name@example.ru", text: $email)
                    .textContentType(.emailAddress)
                    .focused($focus, equals: .email)
                    .disabled(codeEmail != nil || coordinator.isAuthenticating)
            }
            if let codeEmail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Код из письма")
                    TextField("6-значный код", text: $code)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .code)
                        .disabled(coordinator.isAuthenticating)
                }
                Text("Код отправлен на \(codeEmail).").font(.callout).foregroundStyle(.secondary)
            }
            if let error = coordinator.appError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
            HStack {
                Button(codeEmail == nil ? "Получить код" : "Войти") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.isAuthenticating || (codeEmail == nil ? email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : code.count != 6))
                if coordinator.isAuthenticating { ProgressView().controlSize(.small) }
                if codeEmail != nil {
                    Button("Другая почта") { codeEmail = nil; code = ""; focus = .email }
                        .disabled(coordinator.isAuthenticating)
                    Button("Отправить снова") { sendCode() }.disabled(coordinator.isAuthenticating)
                }
            }
            SettingsLink { Text("Настройки") }.font(.callout)
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 400)
        .onSubmit { submit() }
        .onAppear { focus = .email }
        .onDisappear { code = "" }
    }

    private func submit() {
        guard !coordinator.isAuthenticating else { return }
        if let codeEmail {
            let submittedCode = code
            Task {
                if await coordinator.verifyCode(email: codeEmail, code: submittedCode) { code = "" }
            }
        } else { sendCode() }
    }
    private func sendCode() {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        Task {
            if await coordinator.requestCode(email: normalized) {
                email = normalized; codeEmail = normalized; code = ""; focus = .code
            }
        }
    }
}
