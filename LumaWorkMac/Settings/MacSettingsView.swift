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
            Section("Фильтры SimpleOne") {
                ForEach(SimpleOneQueryConfiguration.fields, id: \.key) { field in
                    MacSimpleOneQueryField(key: field.key, title: field.title)
                }
                Text("Идентификаторы сохраняются только на этом Mac. После изменения обновите заявки.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Координация") {
                ForEach(SimpleOneQueryConfiguration.groupArchiveFields, id: \.key) { field in
                    MacSimpleOneQueryField(key: field.key, title: field.title)
                }
                ForEach(CoordinationRegion.allCases) { region in
                    DisclosureGroup(region.title) {
                        ForEach(SimpleOneQueryConfiguration.fields(for: region), id: \.key) { field in
                            MacSimpleOneQueryField(key: field.key, title: field.title)
                        }
                    }
                }
            }
            Section("Приложение") {
                LabeledContent("Версия", value: AppBuildIdentity.display)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }
}

private struct MacSimpleOneQueryField: View {
    let title: String
    @AppStorage private var value: String
    init(key: String, title: String) {
        self.title = title
        _value = AppStorage(wrappedValue: SimpleOneQueryConfiguration().value(for: key), key)
    }
    var body: some View { TextField(title, text: $value).textFieldStyle(.roundedBorder) }
}
