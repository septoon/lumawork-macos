import SwiftUI
import EngineerCore

struct MacSidebarView: View {
    let workspace: MacWorkspaceState
    let user: AppUser
    let openAccount: () -> Void
    let logout: () -> Void
    let selectSection: (EngineerSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<EngineerSection?>(get: { workspace.selectedSection }, set: { if let section = $0 { selectSection(section) } })) {
                ForEach(workspace.availableSections) { section in
                    Label(section.title, systemImage: section.systemImage.replacingOccurrences(of: ".fill", with: ""))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button(action: openAccount) {
                Label(user.profile?.shortDisplayName ?? user.email, systemImage: "person.crop.circle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help("Учётная запись и вход в SimpleOne")
            .accessibilityLabel("Учётная запись")
            .padding(12)
            .contextMenu {
                Button("Учётная запись…", action: openAccount)
                Divider()
                Button("Выйти из Инженера", action: logout)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    }
}
