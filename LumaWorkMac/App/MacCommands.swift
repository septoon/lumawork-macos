import SwiftUI
import EngineerCore

struct MacWorkspaceActions {
    let navigation: MacWorkspaceNavigation
    let availableSections: [EngineerSection]
    let canRefresh: Bool
    let showAccount: () -> Void
    let refresh: () -> Void
    let logout: () -> Void
}

struct MacRouteActions {
    let canSave: Bool
    let canSend: Bool
    let save: () -> Void
    let send: () -> Void
    let refresh: () -> Void
    let archive: () -> Void
}
private struct MacRouteActionsKey: FocusedValueKey { typealias Value = MacRouteActions }

private struct MacWorkspaceActionsKey: FocusedValueKey {
    typealias Value = MacWorkspaceActions
}

extension FocusedValues {
    var routeActions: MacRouteActions? {
        get { self[MacRouteActionsKey.self] }
        set { self[MacRouteActionsKey.self] = newValue }
    }

    var workspaceActions: MacWorkspaceActions? {
        get { self[MacWorkspaceActionsKey.self] }
        set { self[MacWorkspaceActionsKey.self] = newValue }
    }
}

struct MacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceActions) private var workspaceActions
    @FocusedValue(\.routeActions) private var routeActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новое рабочее окно") { openWindow(id: "workspace") }
                .keyboardShortcut("n")
        }
        SidebarCommands()
        CommandMenu("Маршрут") {
            Button("Сохранить черновик") { routeActions?.save() }.keyboardShortcut("s").disabled(routeActions?.canSave != true)
            Button("Отправить…") { routeActions?.send() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(routeActions?.canSend != true)
            Divider()
            Button("Обновить маршрут") { routeActions?.refresh() }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(routeActions == nil)
            Button("Архив маршрутов…") { routeActions?.archive() }.disabled(routeActions == nil)
        }
        CommandMenu("Разделы") {
            ForEach(workspaceActions?.availableSections ?? []) { section in
                Button(section.title) { workspaceActions?.navigation.select(section) }
            }
        }
        CommandMenu("Учётная запись") {
            Button("Учётная запись…") { workspaceActions?.showAccount() }
                .disabled(workspaceActions == nil)
            Button("Проверить соединение") { workspaceActions?.refresh() }
                .keyboardShortcut("r")
                .disabled(workspaceActions?.canRefresh != true)
            Divider()
            Button("Выйти из Инженера") { workspaceActions?.logout() }
                .disabled(workspaceActions == nil)
        }
    }
}
