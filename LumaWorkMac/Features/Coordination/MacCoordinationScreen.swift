import SwiftUI
import Observation
import EngineerCore

enum MacCoordinationSection: String, CaseIterable, Identifiable {
    case distribution, returnEquipment, archive
    var id: String { rawValue }
    var title: String { switch self { case .distribution: "На группу"; case .returnEquipment: "Возврат ТО"; case .archive: "Закрытые группы" } }
}

@MainActor @Observable
final class MacCoordinationWorkspace {
    var section = MacCoordinationSection.distribution
    var region = CoordinationRegion.defaultRegion
    var engineer: String?
    var requests = MacRequestsWorkspace()
    var archive = MacRequestsWorkspace()
    func reset() { engineer = nil; requests.reset(); archive.reset() }
}

struct MacCoordinationScreen: View {
    @Bindable var workspace: MacCoordinationWorkspace
    let repository: RequestsRepository
    let clients: ClientDetailsRepository
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    let openAccount: () -> Void
    private var collection: RequestCollection {
        switch workspace.section { case .distribution: .coordination(workspace.region); case .returnEquipment: .returnEquipment; case .archive: .groupClosed }
    }
    private var engineers: [CoordinationEngineer] { CoordinationPolicy.engineers(repository.records(collection)) }
    var body: some View {
        VStack(spacing: 0) {
            if coordinator.simpleOneSession != nil {
                HStack {
                    Picker("Координация", selection: $workspace.section) { ForEach(MacCoordinationSection.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 370)
                    if workspace.section == .distribution {
                        Picker("Регион", selection: $workspace.region) { ForEach(CoordinationRegion.allCases) { Text($0.title).tag($0) } }.frame(width: 210)
                    }
                    Spacer()
                }.padding(12)
                Divider()
            }
            HSplitView {
                if workspace.section == .distribution, coordinator.simpleOneSession != nil {
                    List(selection: $workspace.engineer) {
                        HStack { Text("Все инженеры"); Spacer(); Text("\(repository.records(collection).count)").foregroundStyle(.secondary) }.tag("all")
                        ForEach(engineers) { engineer in
                            HStack {
                                Text(engineer.name).lineLimit(2)
                                Spacer()
                                Text("\(engineer.requestCount)").monospacedDigit().foregroundStyle(.secondary)
                            }.tag(engineer.id)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
                }
                MacRequestsScreen(workspace: workspace.section == .archive ? workspace.archive : workspace.requests,
                                  repository: repository, clients: clients, coordinator: coordinator, config: config, openAccount: openAccount,
                                  collectionOverride: collection, engineerID: workspace.section == .distribution && workspace.engineer != "all" ? workspace.engineer : nil)
            }
        }
        .onChange(of: workspace.region) { _, _ in workspace.engineer = nil }
        .onChange(of: workspace.section) { _, _ in workspace.engineer = nil }
        .onChange(of: repository.updatedAt(collection)) { _, _ in
            if let id = workspace.engineer, id != "all", !engineers.contains(where: { $0.id == id }) { workspace.engineer = nil }
        }
    }
}
