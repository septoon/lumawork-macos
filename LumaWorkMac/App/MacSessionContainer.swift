import Foundation
import EngineerCore
import CryptoKit

@MainActor
final class MacSessionContainer {
    let config: AppConfig
    let coordinator: EngineerApplicationCoordinator
    private let keychain: MacKeychain
    private var lifecycle: MacLifecycle?
    private var startup: Task<Void, Never>?
    private var snapshots: ScopedSnapshotStorage?
    lazy var requests = RequestsRepository(session: { [coordinator] in coordinator.simpleOneSession },
                                           context: { [coordinator] in coordinator.context },
                                           storage: { [weak self] in
                                               guard let self else { throw SimpleOneServiceError.missingCredentials }
                                               return try self.snapshotStorage()
                                           }, service: { [config] in SimpleOneRequestsService(config: config) },
                                           authFailure: { [coordinator] in coordinator.disconnectSimpleOne() })
    lazy var routes = RouteDayRepository(session: { [coordinator] in coordinator.session },
                                         context: { [coordinator] in coordinator.context },
                                         storage: { [weak self] in
                                             guard let self else { throw RouteRepositoryError.staleSession }
                                             return try self.snapshotStorage()
                                         }, service: { [config] in RouteDayService(config: config, authToken: $0.token) },
                                         authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") },
                                         mapService: { RouteMapCalculator(transport: MacRouteMapTransport()) })

    lazy var gsmFuel = GsmFuelRepository(session: { [coordinator] in coordinator.session },
                                         context: { [coordinator] in coordinator.context },
                                         storage: { [weak self] in
                                             guard let self else { throw GsmFuelError.staleSession }
                                             return try self.snapshotStorage()
                                         }, service: { [config] in GsmFuelService(config: config, authToken: $0.token) },
                                         authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") },
                                         importService: { [config] in FuelImportService(config: config, token: $0.token) })

    lazy var clients = ClientDetailsRepository(session: { [coordinator] in coordinator.session },
                                                context: { [coordinator] in coordinator.context },
                                                storage: { [weak self] in
                                                    guard let self else { throw SnapshotStorageError.missingIdentity }
                                                    return try self.snapshotStorage()
                                                }, service: { [config] in ClientDetailsService(config: config, token: $0.token) },
                                                authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    lazy var vehicles = VehicleMaintenanceRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in VehicleMaintenanceService(config: config, token: $0.token) }, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })
    lazy var salaryAccess = SalaryAccess(context: { [coordinator] in coordinator.context }, generation: { [coordinator] in coordinator.protectedContentGeneration })
    lazy var salaryAuthenticator = MacSalaryAuthenticator(keychain: keychain, config: config, coordinator: coordinator)
    lazy var salary = SalaryRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in SalaryService(config: config, token: $0.token) }, access: salaryAccess, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    lazy var documents = DocumentsRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in DocumentService(config: config, token: $0.token) }, access: salaryAccess, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })
    lazy var ftp = FTPRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in FTPService(config: config, token: $0.token) }, filesRoot: URL.applicationSupportDirectory.appendingPathComponent("EngineerMac/FTP/" + keychain.snapshotNamespace, isDirectory: true), authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })

    lazy var backpack: SimpleOneResourceRepository<[BackpackItem]> = resource("backpack.v1")
    lazy var equipment: SimpleOneResourceRepository<[OfficeEquipmentItem]> = resource("equipment.v1")
    lazy var locations: SimpleOneResourceRepository<[String: BackpackItemLocation]> = resource("backpack-locations.v1")
    lazy var employeeCities: SimpleOneResourceRepository<[SimpleOneEmployeeAddress]> = resource("employee-cities.v1")
    lazy var employeeDirectories: SimpleOneResourceRepository<EmployeeDirectory> = resource("employee-directory.v1")
    lazy var employeeDetails: SimpleOneResourceRepository<SimpleOneEmployee> = resource("employee-detail.v1")
    lazy var scheduleJournals: SimpleOneResourceRepository<[WorkScheduleJournal]> = resource("schedule-journals.v1")
    lazy var schedules: SimpleOneResourceRepository<WorkSchedule> = resource("schedule.v1")
    lazy var equipmentPhotos: SimpleOneResourceRepository<[EquipmentPhoto]> = resource("equipment-photos.v1")
    lazy var images = MacRemoteImageStore(context: { [coordinator] in coordinator.context })
    lazy var profile = ProfileRepository(config: config, session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, applyUser: { [coordinator] user, context in try coordinator.applyUpdatedUser(user, expectedContext: context) }, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") })
    private func resource<Value: Codable & Sendable>(_ namespace: String) -> SimpleOneResourceRepository<Value> {
        SimpleOneResourceRepository(namespace: namespace, session: { [coordinator] in coordinator.simpleOneSession }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
            guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
        }, authFailure: { [coordinator] in coordinator.disconnectSimpleOne() })
    }
    func synchronizeTeam() {
        backpack.synchronizeSession(); equipment.synchronizeSession(); locations.synchronizeSession(); employeeCities.synchronizeSession(); employeeDirectories.synchronizeSession(); employeeDetails.synchronizeSession(); scheduleJournals.synchronizeSession(); schedules.synchronizeSession(); equipmentPhotos.synchronizeSession(); profile.synchronizeSession(); images.synchronizeSession()
    }
    func loadEquipment(office: Bool, force: Bool = false) async {
        // Photo refresh must run even when SimpleOne itself fails.
        async let photos: Void = loadEquipmentPhotos(office: office, force: force)
        do {
            if office {
                try await equipment.load("all", force: force) { [config] session in try await SimpleOneRequestsService(config: config).fetchCurrentOfficeEquipment(authKey: session.authKey) }
            } else {
                let cached = backpack.value("all") ?? []
                try await backpack.load("all", force: force) { [config] session in
                    let service = BackpackService(config: config), items = try await service.fetchItems(authKey: session.authKey)
                    let collector = MacBackpackCollector(items)
                    try await service.hydrateItems(items, cachedItems: cached, authKey: session.authKey) { collector.receive($0) }
                    return collector.items
                }
                try await locations.loadLocal("saved")
                try? await requests.load(.returnEquipment)
            }
        } catch { /* Repository preserves data and exposes the domain error. */ }
        await photos
    }
    private func loadEquipmentPhotos(office: Bool, force: Bool) async {
        try? await equipmentPhotos.load(office ? "office" : "backpack", force: force) { [config] _ in try await EquipmentPhotoService(config: config).manifest(office: office) }
    }

    let notices = MacNoticeCenter()
    lazy var assistantTools = AssistantLocalToolExecutor(requests: requests, backpack: backpack, context: { [coordinator] in coordinator.context }, loadBackpack: { [weak self] in
        guard let self else { throw CancellationError() }
        await self.loadEquipment(office: false)
        guard self.backpack.value("all") != nil else { throw AppServiceError.message(self.backpack.errors["all"] ?? "Войдите в SimpleOne для просмотра оборудования.") }
    })
    lazy var assistant = AssistantRepository(session: { [coordinator] in coordinator.session }, context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [config] in AssistantAPI(config: config, authToken: $0.token) }, executeTools: { [weak self] calls, context in
        guard let self else { throw CancellationError() }; return try await self.assistantTools.execute(calls, expectedContext: context)
    }, authFailure: { [coordinator] in coordinator.invalidateSession(message: "Сессия истекла. Войдите снова.") }, report: { [weak self] in self?.notices.show($0) })
    lazy var wiki = WikiRepository(namespace: "wiki.v1." + SHA256.hash(data: Data((config.wikiAPIOrigin ?? "").utf8)).map { String(format: "%02x", $0) }.joined(), context: { [coordinator] in coordinator.context }, storage: { [weak self] in
        guard let self else { throw SnapshotStorageError.missingIdentity }; return try self.snapshotStorage()
    }, service: { [weak self] in
        guard let self else { throw CancellationError() }; return WikiAPI(config: self.config, token: try self.wikiToken())
    }, report: { [weak self] in self?.notices.show($0) })
    func wikiToken() throws -> String? {
        guard let user = coordinator.session?.user.id else { return nil }
        return try keychain.wikiToken(userID: user, origin: config.wikiAPIOrigin ?? "") ?? config.wikiAPIToken
    }
    func saveWikiToken(_ value: String, context: SessionContext) throws {
        guard coordinator.accepts(context) else { throw CancellationError() }
        try keychain.writeWikiToken(value, userID: context.userID, origin: config.wikiAPIOrigin ?? ""); wiki.synchronizeSession(force: true)
    }
    func synchronizeAssistant() { assistant.synchronizeSession(); wiki.synchronizeSession(); notices.clear() }

    init(config: AppConfig = AppConfig()) {
        self.config = config
        let keychain = MacKeychain(config: config)
        self.keychain = keychain
        coordinator = EngineerApplicationCoordinator(appAPI: LumaWorkAuthAPI(config: config),
                                                       simpleOneAPI: SimpleOneAuthAPI(config: config), credentials: keychain)
    }

    func start() {
        guard startup == nil else { return }
        // Remove only our transient previews/downloads left by a previous terminated process.
        for name in ["EngineerMac-DocumentPreviews", "EngineerMac-FileDownloads", "EngineerMac-RemoteImages", "EngineerMac-AssistantPreviews", "EngineerMac-WikiPreviews"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
        }
        lifecycle = MacLifecycle(coordinator: coordinator)
        startup = Task { [coordinator] in await coordinator.restore() }
    }

    // Created only when a migrated domain needs it. No anonymous directory or hydration.
    func snapshotStorage() throws -> ScopedSnapshotStorage {
        guard coordinator.context != nil else { throw SnapshotStorageError.missingIdentity }
        if let snapshots { return snapshots }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let storage = ScopedSnapshotStorage(root: support.appendingPathComponent("EngineerMac/Snapshots/" + keychain.snapshotNamespace, isDirectory: true),
                                            keyProvider: { [keychain] scope in try await keychain.encryptionKey(for: scope) })
        snapshots = storage
        return storage
    }
}
