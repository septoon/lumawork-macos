import SwiftUI
import EngineerCore

enum MacAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Системное"
        case .light: "Светлое"
        case .dark: "Тёмное"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct MacSettingsView: View {
    @AppStorage("EngineerMac.appearance") private var appearance = MacAppearance.system.rawValue
    private let config = AppConfig()

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Оформление", selection: $appearance) {
                    ForEach(MacAppearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            Section("Подключение") {
                LabeledContent("Сервер", value: config.lumaWorkAPIOrigin ?? "Не настроен")
                    .textSelection(.enabled)
            }
            Section("Приложение") {
                LabeledContent("Версия", value: AppBuildIdentity.display)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }
}
