import SwiftUI
import EngineerCore

struct MacWorkspaceView: View {
    let container: MacSessionContainer
    @Binding var restoredSection: String
    @Binding var restoredUserID: String
    @State private var workspace = MacWorkspaceState()
    @State private var route = MacRouteWorkspace()
    @State private var fuel = MacFuelWorkspace()
    @State private var requests = MacRequestsWorkspace()
    @State private var coordination = MacCoordinationWorkspace()
    @State private var timeReports = MacTimeReportsWorkspace()
    @State private var analytics = MacAnalyticsWorkspace()
    @State private var vehicles = MacVehiclesWorkspace()
    @State private var salary = MacSalaryWorkspace()
    @State private var documents = MacDocumentsWorkspace()
    @State private var ftp = MacFTPWorkspace()
    @State private var equipment = MacEquipmentWorkspace()
    @State private var employees = MacEmployeesWorkspace()
    @State private var profile = MacProfileWorkspace()
    @State private var assistant = MacAssistantWorkspace()
    @SceneStorage("EngineerMac.route.date") private var restoredRouteDate = ""
    @SceneStorage("EngineerMac.route.type") private var restoredRouteType = RouteWorkType.pos.rawValue
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    private var coordinator: EngineerApplicationCoordinator { container.coordinator }

    private var navigation: MacWorkspaceNavigation {
        MacWorkspaceNavigation(state: workspace, currentUser: { coordinator.session?.user }, requestSelection: requestSection)
    }
    private var visibleSection: EngineerSection {
        let allowed = EngineerSection.availableCases(isAdmin: coordinator.session?.user.canAccessAdminPanel ?? false)
        return allowed.contains(workspace.selectedSection) ? workspace.selectedSection : .home
    }
    private var commands: MacWorkspaceActions {
        MacWorkspaceActions(navigation: navigation,
                            availableSections: EngineerSection.availableCases(isAdmin: coordinator.session?.user.canAccessAdminPanel ?? false),
                            canRefresh: coordinator.context != nil && !coordinator.isAuthenticating,
                            showAccount: { if coordinator.session != nil { workspace.isAccountPresented = true } },
                            refresh: {
                                guard coordinator.context != nil, !coordinator.isAuthenticating else { return }
                                Task { await coordinator.refreshSession() }
                            }, logout: {
                                guard coordinator.session != nil else { return }
                                let userID = coordinator.session?.user.id
                                workspace.isAccountPresented = false
                                Task {
                                    guard await MacDraftRegistry.shared.confirm(), coordinator.session?.user.id == userID else { return }
                                    await coordinator.logout()
                                }
                            })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if let user = coordinator.session?.user {
                MacSidebarView(workspace: workspace, user: user,
                               openAccount: { workspace.isAccountPresented = true }, logout: commands.logout, selectSection: requestSection)
            }
        } detail: {
            VStack(spacing: 0) {
                if coordinator.appConnection == .offline {
                    Label("Нет связи с сервером. Сессия сохранена локально.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Divider()
                }
                Group {
                    if visibleSection == .home {
                        MacHomeScreen(model: route, repository: container.routes, coordinator: coordinator,
                                      mapsRouteURL: container.config.mapsRouteURL, openGsm: { fuel.isGsmPresented = true },
                                      changeDate: { date in requestRouteDay(date: date, workType: route.workType) },
                                      changeWorkType: { type in requestRouteDay(date: route.selectedDate, workType: type) },
                                      openArchivedDay: { record in requestRouteDay(date: MacRouteDate.date(record.date) ?? Date(), workType: record.workType) })
                    } else if visibleSection == .fuel {
                        MacFuelScreen(workspace: fuel, repository: container.gsmFuel, vehicles: container.vehicles, routes: container.routes, coordinator: coordinator, archiveOwnerEmail: container.config.fuelArchiveOwnerEmail)
                    } else if visibleSection == .maintenance {
                        MacVehiclesScreen(workspace: vehicles, repository: container.vehicles, documents: container.documents, coordinator: coordinator, profileChanged: { Task { try? await container.gsmFuel.loadGsm(force: true) } })
                    } else if visibleSection == .salary {
                        MacSalaryScreen(workspace: salary, repository: container.salary, documents: container.documents, access: container.salaryAccess, authenticator: container.salaryAuthenticator, coordinator: coordinator)
                    } else if visibleSection == .backpack {
                        MacEquipmentScreen(model: equipment, container: container, openAccount: { workspace.isAccountPresented = true })
                    } else if visibleSection == .employees {
                        MacEmployeesScreen(model: employees, container: container, openAccount: { workspace.isAccountPresented = true })
                    } else if visibleSection == .wiki {
                        MacAssistantScreen(model: assistant, container: container)
                    } else if visibleSection == .ftp {
                        MacFTPScreen(workspace: ftp, repository: container.ftp, coordinator: coordinator)
                    } else if visibleSection == .requests {
                        MacRequestsScreen(workspace: requests, repository: container.requests, clients: container.clients, coordinator: coordinator, config: container.config,
                                          openAccount: { workspace.isAccountPresented = true })
                    } else if visibleSection == .coordination {
                        MacCoordinationScreen(workspace: coordination, repository: container.requests, clients: container.clients, coordinator: coordinator, config: container.config,
                                              openAccount: { workspace.isAccountPresented = true })
                    } else if visibleSection == .timeReport {
                        MacTimeReportsScreen(workspace: timeReports, repository: container.requests, coordinator: coordinator, config: container.config,
                                             openAccount: { workspace.isAccountPresented = true })
                    } else if visibleSection == .analytics {
                        MacAnalyticsScreen(workspace: analytics, repository: container.requests, coordinator: coordinator,
                                           openAccount: { workspace.isAccountPresented = true })
                    } else {
                        ContentUnavailableView(visibleSection.title, systemImage: visibleSection.systemImage.replacingOccurrences(of: ".fill", with: ""), description: Text("Раздел пока недоступен."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 700)
            .navigationTitle(visibleSection.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: commands.refresh) { Label("Проверить соединение", systemImage: "arrow.clockwise") }
                        .disabled(!commands.canRefresh)
                        .help("Проверить соединение")
                    Button(action: commands.showAccount) { Label("Учётная запись", systemImage: "person.crop.circle") }
                        .help("Учётная запись и вход в SimpleOne")
                }
            }
        }
        .overlay(alignment: .bottom) { MacNoticeBanner(center: container.notices) }
        .focusedSceneValue(\.workspaceActions, commands)
        .focusedSceneValue(\.routeActions, visibleSection == .home ? routeActions : nil)
        .background(MacWindowDraftGuard(id: workspace.windowID, hasDirty: { route.draft?.isDirty == true || fuel.hasDirty || hasDirtyClient || vehicles.hasDirty || salary.hasDirty || documents.hasDirty || profile.hasDirty || assistant.hasDirty },
                                        save: { try await route.save(repository: container.routes) }, discard: { if assistant.hasDirty { assistant.discardComposer() } else if profile.hasDirty { profile.reset() } else if documents.hasDirty { documents.reset() } else if salary.hasDirty { salary.discardEditor() } else if vehicles.hasDirty { vehicles.discardEditors() } else if hasDirtyClient { discardClients() } else if fuel.hasDirty { fuel.discardEditors() } else { route.draft?.discard() } }, discardOnly: { fuel.hasDirty || hasDirtyClient || vehicles.hasDirty || salary.hasDirty || documents.hasDirty || profile.hasDirty || assistant.hasDirty }))
        .sheet(isPresented: $workspace.isAccountPresented) { MacAccountView(container: container, profile: profile, documentsWorkspace: documents, logout: commands.logout, navigate: { section in requestWindowAction { profile.isPresented = false; workspace.isAccountPresented = false; workspace.select(section) } }) }
        .sheet(isPresented: Binding(get: { visibleSection == .home && fuel.isGsmPresented }, set: { fuel.isGsmPresented = $0 })) {
            MacGsmReportScreen(workspace: fuel, repository: container.gsmFuel, vehicles: container.vehicles, coordinator: coordinator, selectedDate: route.selectedDate,
                               applyOdometer: { month, value in
                                   guard String(route.key.date.prefix(7)) == month, !route.isBusy else { return }
                                   route.draft?.setOdometer(value); route.notice = "Одометр применён к черновику маршрута."
                               })
        }
        .onAppear {
            workspace.reconcile(user: coordinator.session?.user, restoredSection: restoredSection, restoredUserID: restoredUserID)
            persistSelection()
            if let date = MacRouteDate.date(restoredRouteDate) { route.selectedDate = date }
            route.workType = RouteWorkType(rawValue: restoredRouteType) ?? .pos
            container.routes.synchronizeSession(); container.gsmFuel.synchronizeSession(); container.requests.synchronizeSession(); container.clients.synchronizeSession(); container.vehicles.synchronizeSession(); container.salary.synchronizeSession(); container.documents.synchronizeSession(); container.ftp.synchronizeSession(); container.synchronizeTeam(); container.synchronizeAssistant()
        }
        .onChange(of: coordinator.context) { _, _ in
            container.routes.synchronizeSession(); container.gsmFuel.synchronizeSession(); container.requests.synchronizeSession(); container.clients.synchronizeSession(); container.vehicles.synchronizeSession(); container.salary.synchronizeSession(); container.documents.synchronizeSession(); container.ftp.synchronizeSession(); container.synchronizeTeam(); container.synchronizeAssistant()
            assistant.reset(); equipment.reset(); employees.reset(); profile.reset(); documents.reset(); ftp.reset(); fuel.reset(); requests.reset(); coordination.reset(); timeReports.reset(); analytics.reset(); vehicles.reset(); salary.lock(access: container.salaryAccess, authenticator: container.salaryAuthenticator); salary.hidesAmounts = true
        }
        .onChange(of: route.selectedDate) { _, date in restoredRouteDate = MacRouteDate.key(date) }
        .onChange(of: route.workType) { _, type in restoredRouteType = type.rawValue }
        .onChange(of: coordinator.session?.user) { _, user in
            workspace.reconcile(user: user)
            persistSelection()
        }
        .onChange(of: workspace.selectedSection) { old, new in
            if old == .salary && new != .salary { salary.isPresented = false; salary.lock(access: container.salaryAccess, authenticator: container.salaryAuthenticator) }
            persistSelection()
        }
        .onChange(of: coordinator.protectedContentGeneration) { _, _ in
            if !container.salaryAccess.accepts(salary.grant) {
                salary.lock(access: container.salaryAccess, authenticator: container.salaryAuthenticator, cancelAuthentication: false)
            }
        }
        .onChange(of: coordinator.protectedAuthenticationGeneration) { _, _ in
            salary.lock(access: container.salaryAccess, authenticator: container.salaryAuthenticator)
        }
        .onDisappear { assistant.reset(); salary.isPresented = false; salary.lock(access: container.salaryAccess, authenticator: container.salaryAuthenticator) }
    }

    private var hasDirtyClient: Bool { requests.hasDirtyClient || coordination.requests.hasDirtyClient || coordination.archive.hasDirtyClient }
    private func discardClients() { requests.discardClientDraft(); coordination.requests.discardClientDraft(); coordination.archive.discardClientDraft() }

    private var routeActions: MacRouteActions {
        MacRouteActions(canSave: route.draft?.isDirty == true && !route.isBusy,
                        canSend: route.draft != nil && route.draft?.validationMessage == nil && !route.isBusy && !route.isLoading && !route.isMapPresented,
                        save: { Task { await route.saveShowingError(repository: container.routes) } },
                        send: { route.isSendConfirmationPresented = true },
                        refresh: { Task { await route.load(repository: container.routes, coordinator: coordinator, force: true) } },
                        archive: { route.isArchivePresented = true }, map: { route.isMapPresented = true })
    }
    private func requestSection(_ section: EngineerSection) {
        guard section != workspace.selectedSection else { return }
        requestWindowAction { workspace.reconcile(user: coordinator.session?.user); workspace.select(section) }
    }
    private func requestRouteDay(date: Date, workType: RouteWorkType) {
        guard RouteDayKey(date: MacRouteDate.key(date), workType: workType) != route.key, !route.isBusy else { return }
        requestWindowAction { route.selectedDate = date; route.workType = workType }
    }
    private func requestWindowAction(_ action: @escaping () -> Void) {
        let userID = coordinator.session?.user.id
        Task {
            guard await MacDraftRegistry.shared.confirm(workspace.windowID), coordinator.session?.user.id == userID else { return }
            action()
        }
    }

    private func persistSelection() {
        restoredSection = workspace.selectedSection.rawValue
        restoredUserID = coordinator.session?.user.id ?? ""
    }
}
