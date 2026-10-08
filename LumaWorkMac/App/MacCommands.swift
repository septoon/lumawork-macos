import SwiftUI

struct MacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новое рабочее окно") { openWindow(id: "workspace") }
                .keyboardShortcut("n")
        }
    }
}
