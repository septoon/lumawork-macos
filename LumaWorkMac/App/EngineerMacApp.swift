import SwiftUI

@main
struct EngineerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var sessionContainer = MacSessionContainer()
    @AppStorage("EngineerMac.appearance") private var appearance = MacAppearance.system.rawValue

    var body: some Scene {
        WindowGroup("Инженер", id: "workspace") {
            MacRootView(container: sessionContainer)
                .preferredColorScheme(MacAppearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MacCommands() }

        Settings {
            MacSettingsView()
                .preferredColorScheme(MacAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
